local _, RB = ...

-- Sincronización entre jugadores con RushBot por hermandad, grupo y amigos
-- de Battle.net (en WoW retail).
--
-- Unidad de sincronización = "registro":
--   "tag/Nombre-Reino"  → un personaje (versión = max(updated, rolesTs))
--   "tag/"              → datos de la cuenta (Discord ID; versión = discordTs)
--
-- Protocolo (cada mensaje lógico se trocea en partes de <255 bytes):
--   H<digest>   HELLO: lista "tag/char=versión;..." de todo lo que tengo
--   R<digest>   petición: "quiero esto, yo tengo esta versión"
--   C<campos>   un personaje
--   A<campos>   una cuenta
--   P / Q       ping / pong entre amigos de Battle.net
-- Al recibir un HELLO se responde con lo que le falta al otro (envío) y con
-- lo que me falta a mí (petición). Los envíos esperan 1-5 s al azar y se
-- cancelan si otro jugador del canal envía antes lo mismo. Gana siempre la
-- versión más nueva (GetServerTime).

local Sync = {}
RB.Sync = Sync

local PREFIX = "RushBot"
local MAX_PART = 240          -- bytes de datos por mensaje (cabecera aparte)
local MAX_PARTS = 40
local BUCKET_MAX, BUCKET_RATE = 8, 1   -- ráfaga y mensajes/segundo por canal
local MAX_QUEUE = 4000
local MAX_ACCOUNTS, MAX_CHARS = 1000, 60
local FS = "~"

local issecret = issecretvalue or function() return false end

C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------

local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local i = s:find(sep, pos, true)
    if not i then
      out[#out + 1] = s:sub(pos)
      return out
    end
    out[#out + 1] = s:sub(pos, i - 1)
    pos = i + 1
  end
end

-- quita los separadores del protocolo y códigos de control
local function clean(s, maxLen)
  s = tostring(s or ""):gsub("[~;,=/:|%c]", "")
  if maxLen and #s > maxLen then s = s:sub(1, maxLen) end
  return s
end

local function num(s, max)
  local n = tonumber(s)
  if not n or n < 0 or (max and n > max) then return nil end
  return math.floor(n)
end

local function charVer(c)
  return math.max(c.updated or 0, c.rolesTs or 0)
end

local VALID_ROLE = { TANK = true, HEALER = true, DAMAGER = true }
local ROLE_CODE = { TANK = "T", HEALER = "H", DAMAGER = "D" }
local CODE_ROLE = { T = "TANK", H = "HEALER", D = "DAMAGER" }

---------------------------------------------------------------------------
-- Serialización
---------------------------------------------------------------------------

local function encodeGear(g)
  local out = {}
  for cat, t in pairs(g or {}) do
    if RB.SLOT_LABELS[cat] then
      out[#out + 1] = ("%s:%d:%d"):format(cat, t[1] or 0, t[2] or 0)
    end
  end
  table.sort(out) -- orden estable: la firma no cambia sin cambios reales
  return table.concat(out, ",")
end

local function decodeGear(s)
  local g = {}
  for cat, a, b in s:gmatch("(%u+):(%d+):(%d+)") do
    if RB.SLOT_LABELS[cat] then
      g[cat] = { tonumber(a), tonumber(b), "S", "S" }
    end
  end
  return g
end

local function encodeRoles(roles)
  if not roles then return "*" end -- nunca tocados: se usa el de la spec
  local s = ""
  for _, role in ipairs(RB.ROLE_ORDER) do
    if roles[role] then s = s .. ROLE_CODE[role] end
  end
  return s
end

local function decodeRoles(s)
  if s == "*" then return nil end
  local set = {}
  for code in s:gmatch(".") do
    if CODE_ROLE[code] then set[CODE_ROLE[code]] = true end
  end
  return set
end

-- Campos del personaje que se comparten (sin marcas de tiempo ni origen).
local function charFields(c)
  local key = c.key
  return {
    clean(c.name, 64), clean(c.realm, 64), clean(c.class, 16), c.specID or 0,
    c.role or "", c.faction == "Horde" and "H" or (c.faction == "Alliance" and "A" or ""),
    c.ilvl or 0, c.score or 0, key and key.map or 0, key and key.level or 0,
    encodeGear(c.gear), encodeGear(c.bank), c.bankScanned and 1 or 0,
  }
end

-- Firma para saber si un escaneo cambió algo que merezca sincronizarse.
function RB:CharSignature(c)
  return table.concat(charFields(c), FS)
end

local function encodeChar(tag, key, c)
  local f = charFields(c)
  f[#f + 1] = c.bankScanned or 0
  f[#f + 1] = c.updated or 0
  f[#f + 1] = encodeRoles(c.roles)
  f[#f + 1] = c.rolesTs or 0
  f[#f + 1] = clean(RB:GetMyTag())
  return "C" .. clean(tag) .. FS .. clean(key) .. FS .. table.concat(f, FS)
end

local function encodeAccount(tag, acc)
  return "A" .. table.concat({ clean(tag), acc.discordId or "", acc.discordTs or 0, clean(RB:GetMyTag()) }, FS)
end

-- BattleTag: letras/dígitos + # + número. Sin espacios, símbolos ni códigos
-- de color/enlace del juego (los datos llegan de otros jugadores).
local function validTag(tag)
  return tag and #tag <= 64 and tag:match("^[^%s%c%p]+#%d+$") ~= nil
end
local function validCharKey(key)
  return key and #key <= 100 and key:match("^[^%-%c|@]+%-[^%c|@]+$") ~= nil
end

---------------------------------------------------------------------------
-- Registros y versiones
---------------------------------------------------------------------------

local function recKey(tag, charKey) return tag .. "/" .. (charKey or "") end

local function parseRecKey(rk)
  return rk:match("^([^/]+)/(.*)$")
end

local function versionOf(rk)
  local tag, key = parseRecKey(rk)
  local acc = tag and RB.db.accounts[tag]
  if not acc then return 0 end
  if key == "" then return acc.discordTs or 0 end
  local c = acc.chars[key]
  return c and c.updated and charVer(c) or 0
end

-- Privacidad: los datos de otras cuentas solo se reenvían por hermandad.
-- Por grupo y Battle.net cada uno comparte únicamente su propia cuenta.
local function canShare(dest, tag)
  return dest.kind == "GUILD" or tag == RB:GetMyTag()
end

local function digest(dest)
  local list = {}
  for tag, acc in pairs(RB.db.accounts) do
    if canShare(dest, tag) then
      if acc.discordTs then list[#list + 1] = recKey(tag, "") .. "=" .. acc.discordTs end
      for key, c in pairs(acc.chars) do
        if c.updated then list[#list + 1] = recKey(tag, key) .. "=" .. charVer(c) end
      end
    end
  end
  return list
end

local function encodeRecord(rk)
  local tag, key = parseRecKey(rk)
  local acc = tag and RB.db.accounts[tag]
  if not acc then return nil end
  if key == "" then
    return acc.discordTs and encodeAccount(tag, acc) or nil
  end
  local c = acc.chars[key]
  return c and c.updated and encodeChar(tag, key, c) or nil
end

---------------------------------------------------------------------------
-- Destinos y cola de envío
---------------------------------------------------------------------------

local DEST_GUILD = { kind = "GUILD", key = "GUILD" }
local DEST_GROUP = { kind = "GROUP", key = "GROUP" }
local bnDests = {}
local function bnDest(id)
  local d = bnDests[id]
  if not d then
    d = { kind = "BN", key = "BN:" .. id, id = id }
    bnDests[id] = d
  end
  return d
end

Sync.peers = {} -- [gameAccountID] = GetTime() del último mensaje recibido

local function groupChannel()
  if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if IsInRaid() then return "RAID" end
  if IsInGroup() then return "PARTY" end
end

local function activeDests()
  local list = {}
  if IsInGuild() then list[#list + 1] = DEST_GUILD end
  if IsInGroup() then list[#list + 1] = DEST_GROUP end
  for id in pairs(Sync.peers) do list[#list + 1] = bnDest(id) end
  return list
end

-- Midnight: nada de mensajes de addon en combate ni dentro de instancias.
function Sync:CanSend()
  if InCombatLockdown() then return false end
  if IsInInstance() then return false end
  if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return false end
  return true
end

local queue = {}
local tokens = { GUILD = BUCKET_MAX, GROUP = BUCKET_MAX, BN = BUCKET_MAX }
local seq = math.random(1, 9000)
local warnedFull = false

local function enqueue(dest, payload)
  seq = seq % 9999 + 1
  local parts, pos, n = {}, 1, #payload
  while pos <= n do
    local last = math.min(pos + MAX_PART - 1, n)
    -- no partir un carácter UTF-8 por la mitad
    while last < n and last > pos do
      local b = payload:byte(last + 1)
      if b >= 0x80 and b < 0xC0 then last = last - 1 else break end
    end
    parts[#parts + 1] = payload:sub(pos, last)
    pos = last + 1
  end
  if #parts == 0 or #parts > MAX_PARTS then return end
  if #queue + #parts > MAX_QUEUE then
    if not warnedFull then
      warnedFull = true
      RB:Print("Cola de sincronización llena; se descartan envíos.")
    end
    return
  end
  for i, p in ipairs(parts) do
    queue[#queue + 1] = { dest = dest, msg = ("%d,%d,%d:%s"):format(seq, i, #parts, p) }
  end
end

local THROTTLED = {}
if Enum.SendAddonMessageResult then
  local r = Enum.SendAddonMessageResult
  if r.AddonMessageThrottle then THROTTLED[r.AddonMessageThrottle] = true end
  if r.ChannelThrottle then THROTTLED[r.ChannelThrottle] = true end
end

-- true = hecho (enviado o descartado), false = reintentar más tarde
local function rawSend(dest, msg)
  if dest.kind == "BN" then
    pcall(BNSendGameData, dest.id, PREFIX, msg)
    return true
  end
  local chan
  if dest.kind == "GUILD" then
    chan = IsInGuild() and "GUILD" or nil
  else
    chan = groupChannel()
  end
  if not chan then return true end
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, chan)
  if ok and THROTTLED[res] then return false end
  return true
end

local lastTick = GetTime()
local buffers = {}

local function tick()
  local now = GetTime()
  local dt = now - lastTick
  lastTick = now
  for kind, n in pairs(tokens) do
    tokens[kind] = math.min(BUCKET_MAX, n + dt * BUCKET_RATE)
  end

  -- trozos incompletos de hace más de un minuto: fuera
  for k, b in pairs(buffers) do
    if now - b.t > 60 then buffers[k] = nil end
  end

  if #queue == 0 or not Sync:CanSend() then return end
  local rest = {}
  for _, item in ipairs(queue) do
    local kind = item.dest.kind
    if tokens[kind] >= 1 then
      if rawSend(item.dest, item.msg) then
        tokens[kind] = tokens[kind] - 1
      else
        tokens[kind] = 0
        rest[#rest + 1] = item
      end
    else
      rest[#rest + 1] = item
    end
  end
  queue = rest
  if #queue == 0 then warnedFull = false end
end

C_Timer.NewTicker(0.25, tick)

function Sync:QueueSize() return #queue end

---------------------------------------------------------------------------
-- Envíos con espera aleatoria (anti-avalancha)
---------------------------------------------------------------------------

local pendingPush = {} -- [destKey|recKey] = token
local pushToken = 0

function Sync:SchedulePush(dest, rk)
  if not canShare(dest, (parseRecKey(rk))) then return end
  local k = dest.key .. "|" .. rk
  if pendingPush[k] then return end
  pushToken = pushToken + 1
  local token = pushToken
  pendingPush[k] = token
  C_Timer.After(1 + math.random() * 4, function()
    if pendingPush[k] ~= token then return end -- cancelado: otro lo envió antes
    pendingPush[k] = nil
    local payload = encodeRecord(rk)
    if payload then enqueue(dest, payload) end
  end)
end

local function cancelPush(dest, rk)
  pendingPush[dest.key .. "|" .. rk] = nil
end

local localPending = {}
-- Un dato propio ha cambiado: enviarlo (directo) a todos los canales.
function Sync:LocalChanged(tag, charKey)
  if not tag or not charKey then return end
  local rk = recKey(tag, charKey)
  if localPending[rk] then return end
  localPending[rk] = true
  C_Timer.After(15, function()
    localPending[rk] = nil
    for _, dest in ipairs(activeDests()) do Sync:SchedulePush(dest, rk) end
  end)
end

---------------------------------------------------------------------------
-- HELLO
---------------------------------------------------------------------------

local function sendDigest(dest, typ, list)
  if #list == 0 then return end
  -- cada mensaje lógico lleva una parte del digest; así no crece sin límite
  local cur = {}
  local size = 0
  for _, entry in ipairs(list) do
    if size + #entry > MAX_PART * 8 and #cur > 0 then
      enqueue(dest, typ .. table.concat(cur, ";"))
      cur, size = {}, 0
    end
    cur[#cur + 1] = entry
    size = size + #entry + 1
  end
  if #cur > 0 then enqueue(dest, typ .. table.concat(cur, ";")) end
end

function Sync:SendHello(dest)
  local list = digest(dest)
  if #list == 0 then list = { "-" } end -- HELLO vacío: "no tengo nada"
  sendDigest(dest, "H", list)
end

local function retailFriendAccounts()
  local ids = {}
  if not (C_BattleNet and C_BattleNet.GetFriendNumGameAccounts) then return ids end
  local total = BNGetNumFriends() or 0
  for i = 1, total do
    for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) or 0 do
      local ga = C_BattleNet.GetFriendGameAccountInfo(i, j)
      if ga and ga.isOnline and ga.gameAccountID and ga.clientProgram == BNET_CLIENT_WOW
        and ga.wowProjectID == WOW_PROJECT_MAINLINE then
        ids[#ids + 1] = ga.gameAccountID
      end
    end
  end
  return ids
end

-- HELLO a hermandad y grupo; ping a los amigos de Battle.net (solo los que
-- respondan con RushBot reciben luego el HELLO).
function Sync:HelloAll()
  if not RB.db then return end
  if IsInGuild() then self:SendHello(DEST_GUILD) end
  if IsInGroup() then self:SendHello(DEST_GROUP) end
  for _, id in ipairs(retailFriendAccounts()) do
    enqueue(bnDest(id), "P")
  end
end

---------------------------------------------------------------------------
-- Recepción
---------------------------------------------------------------------------

local function parseDigest(body)
  local out = {}
  for entry in body:gmatch("[^;]+") do
    local rk, ver = entry:match("^([^=]+/[^=]*)=(%d+)$")
    if rk then out[rk] = tonumber(ver) end
  end
  return out
end

local function onHello(dest, body)
  local theirs = parseDigest(body)
  local want = {}
  for rk, ver in pairs(theirs) do
    local mine = versionOf(rk)
    if ver > mine then
      want[#want + 1] = rk .. "=" .. mine
    elseif mine > ver then
      Sync:SchedulePush(dest, rk)
    end
  end
  -- lo que yo tengo y el otro ni menciona
  for _, entry in ipairs(digest(dest)) do
    local rk = entry:match("^(.-)=%d+$")
    if rk and not theirs[rk] then Sync:SchedulePush(dest, rk) end
  end
  sendDigest(dest, "R", want)
end

local function onRequest(dest, body)
  for rk, ver in pairs(parseDigest(body)) do
    if versionOf(rk) > ver then Sync:SchedulePush(dest, rk) end
  end
end

local function countChars(acc)
  local n = 0
  for _ in pairs(acc.chars) do n = n + 1 end
  return n
end

local function countAccounts()
  local n = 0
  for _ in pairs(RB.db.accounts) do n = n + 1 end
  return n
end

-- Crea la cuenta solo si cabe (evita que datos basura llenen la BD).
local function getAccountFor(tag)
  local acc = RB.db.accounts[tag]
  if acc then return acc end
  if countAccounts() >= MAX_ACCOUNTS then return nil end
  return RB:GetAccount(tag, true)
end

local refreshPending = false
local function dataChanged()
  if refreshPending then return end
  refreshPending = true
  C_Timer.After(0.5, function()
    refreshPending = false
    if RB.UI then RB.UI:RefreshIfShown() end
  end)
end

local function onChar(dest, body)
  local f = split(body, FS)
  if #f < 20 then return end
  local tag, key = f[1], f[2]
  if not validTag(tag) or not validCharKey(key) then return end
  local class = f[5]
  if not RAID_CLASS_COLORS[class] then return end
  local updated, rolesTs = num(f[17]), num(f[19]) or 0
  if not updated or updated == 0 then return end
  local future = RB:Now() + 300 -- no aceptar fechas del futuro
  if updated > future or rolesTs > future then return end
  local rk = recKey(tag, key)

  local acc = getAccountFor(tag)
  if not acc then return end
  local c = acc.chars[key]
  if not c then
    if countChars(acc) >= MAX_CHARS then return end
    c = {}
    acc.chars[key] = c
  end

  -- lo escaneado en este PC manda: nadie lo sobrescribe desde fuera
  local mine = tag == RB:GetMyTag() and c.updated and c.src == nil
  if mine then
    cancelPush(dest, rk)
    return
  end

  local changed = false
  if updated > (c.updated or 0) then
    local specID = num(f[6]) or 0
    local mapID, level = num(f[11]) or 0, num(f[12], 100) or 0
    c.name = clean(f[3], 64)
    c.realm = clean(f[4], 64)
    c.class = class
    c.classLoc = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
    c.specID = specID > 0 and specID or nil
    c.spec = specID > 0 and select(2, GetSpecializationInfoByID(specID)) or nil
    c.role = VALID_ROLE[f[7]] and f[7] or nil
    c.faction = (f[8] == "H" and "Horde") or (f[8] == "A" and "Alliance") or nil
    c.ilvl = num(f[9], 2000) or 0
    c.score = num(f[10], 20000)
    if c.score == 0 then c.score = nil end
    if mapID > 0 and level > 0 then
      c.key = { map = mapID, level = level, name = C_ChallengeMode.GetMapUIInfo(mapID) }
    else
      c.key = nil
    end
    c.gear = decodeGear(f[13])
    local bankScanned = num(f[16]) or 0
    if f[15] == "1" and bankScanned > 0 then
      c.bank, c.bankScanned = decodeGear(f[14]), bankScanned
    else
      c.bank, c.bankScanned = nil, nil
    end
    c.updated = updated
    local origin = clean(f[20])
    c.src = origin == tag and "direct" or "relay"
    c.via = origin
    changed = true
  end
  if rolesTs > (c.rolesTs or 0) then
    c.roles = decodeRoles(f[18])
    c.rolesTs = rolesTs
    changed = true
  end
  if not c.updated then
    acc.chars[key] = nil -- solo traía roles de un personaje desconocido
    return
  end

  -- alguien ya lo ha enviado a este canal: no repetirlo; si lo mío es más
  -- nuevo, corregir al canal
  local incoming = math.max(updated, rolesTs)
  if charVer(c) > incoming then
    Sync:SchedulePush(dest, rk)
  else
    cancelPush(dest, rk)
  end
  if changed then dataChanged() end
end

local function onAccount(dest, body)
  local f = split(body, FS)
  if #f < 4 then return end
  local tag, id, ts = f[1], f[2], num(f[3])
  if not validTag(tag) or not ts or ts == 0 or ts > RB:Now() + 300 then return end
  if id ~= "" and not RB:IsValidDiscordId(id) then return end
  local rk = recKey(tag, "")
  local acc = getAccountFor(tag)
  if not acc then return end
  -- mi propio Discord ID, puesto en este PC, no se cambia desde fuera
  if tag == RB:GetMyTag() and acc.discordId and acc.discordSrc == nil then
    cancelPush(dest, rk)
    return
  end
  if ts > (acc.discordTs or 0) then
    acc.discordId = id ~= "" and id or nil
    acc.discordTs = ts
    local origin = clean(f[4])
    acc.discordSrc = origin == tag and "direct" or "relay"
    dataChanged()
  end
  if (acc.discordTs or 0) > ts then
    Sync:SchedulePush(dest, rk)
  else
    cancelPush(dest, rk)
  end
end

function Sync:OnPayload(dest, payload)
  if not RB.db then return end
  local t, body = payload:sub(1, 1), payload:sub(2)
  if t == "H" then
    onHello(dest, body)
  elseif t == "R" then
    onRequest(dest, body)
  elseif t == "C" then
    onChar(dest, body)
  elseif t == "A" then
    onAccount(dest, body)
  elseif t == "P" and dest.kind == "BN" then
    enqueue(dest, "Q")
  elseif t == "Q" and dest.kind == "BN" then
    self:SendHello(dest)
  end
end

function Sync:OnChunk(dest, sender, text)
  local id, idx, total, part = text:match("^(%d+),(%d+),(%d+):(.*)$")
  idx, total = tonumber(idx), tonumber(total)
  if not id or not idx or not total or total < 1 or total > MAX_PARTS or idx < 1 or idx > total then return end
  if total == 1 then return self:OnPayload(dest, part) end
  local k = sender .. "#" .. id
  local b = buffers[k]
  if not b then
    b = { n = 0, total = total, t = GetTime() }
    buffers[k] = b
  end
  if b.total ~= total or b[idx] then return end
  b[idx] = part
  b.n = b.n + 1
  if b.n == total then
    buffers[k] = nil
    self:OnPayload(dest, table.concat(b, "", 1, total))
  end
end

RB:On("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
  if prefix ~= PREFIX then return end
  if issecret(text) or issecret(sender) or issecret(channel) then return end
  if not sender or Ambiguate(sender, "none") == UnitName("player") then return end
  local dest
  if channel == "GUILD" then
    dest = DEST_GUILD
  elseif channel == "PARTY" or channel == "RAID" or channel == "INSTANCE_CHAT" then
    dest = DEST_GROUP
  else
    return
  end
  Sync:OnChunk(dest, sender, text)
end)

RB:On("BN_CHAT_MSG_ADDON", function(_, prefix, text, _, gameAccountID)
  if prefix ~= PREFIX or not gameAccountID then return end
  if issecret(text) then return end
  Sync.peers[gameAccountID] = GetTime()
  Sync:OnChunk(bnDest(gameAccountID), "BN:" .. gameAccountID, text)
end)

---------------------------------------------------------------------------
-- Disparadores
---------------------------------------------------------------------------

RB:On("PLAYER_LOGIN", function()
  C_Timer.After(15 + math.random() * 10, function() Sync:HelloAll() end)
end)

-- al entrar gente en el grupo: HELLO al grupo (como mucho uno cada 30 s)
local lastGroupSize, lastGroupHello, groupPending = 0, 0, false
RB:On("GROUP_ROSTER_UPDATE", function()
  local size = GetNumGroupMembers()
  local grew = size > lastGroupSize
  lastGroupSize = size
  if not grew or size < 2 or groupPending then return end
  groupPending = true
  local wait = math.max(3, 30 - (GetTime() - lastGroupHello))
  C_Timer.After(wait + math.random() * 2, function()
    groupPending = false
    if IsInGroup() then
      lastGroupHello = GetTime()
      Sync:SendHello(DEST_GROUP)
    end
  end)
end)
