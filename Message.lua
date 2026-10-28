local _, RB = ...

-- Discord corta a 2000 caracteres; dejamos margen (y # cuenta bytes, no letras).
local MAX_LEN = 1900
local SEP = " --- "

-- Emojis del servidor de Discord. Si en vuestro servidor se llaman distinto,
-- cambia aquí el nombre (Discord distingue mayúsculas).
local E = {
  Alliance = ":alliance:", Horde = ":horde:",
  TANK = ":Tank:", HEALER = ":Heal:", DAMAGER = ":DPS:",
  score = ":Raiderio:", key = ":Keystone:", ilvl = ":gear:", warn = ":warning:",
}

local CLASS_EMOJI = {
  WARRIOR = ":warrior:", PALADIN = ":paladin:", DEATHKNIGHT = ":deathknight:",
  HUNTER = ":hunter:", SHAMAN = ":shaman:", EVOKER = ":evoker:",
  DRUID = ":druid:", ROGUE = ":rogue:", MONK = ":monk:", DEMONHUNTER = ":demonhunter:",
  MAGE = ":mage:", PRIEST = ":priest:", WARLOCK = ":warlock:",
}

local CLASS_EN = {
  WARRIOR = "Warrior", PALADIN = "Paladin", DEATHKNIGHT = "Death Knight",
  HUNTER = "Hunter", SHAMAN = "Shaman", EVOKER = "Evoker",
  DRUID = "Druid", ROGUE = "Rogue", MONK = "Monk", DEMONHUNTER = "Demon Hunter",
  MAGE = "Mage", PRIEST = "Priest", WARLOCK = "Warlock",
}

-- Mazmorras M+ por challengeMapID: abreviatura y nombre en inglés, iguales en
-- cualquier idioma del cliente. /rush keys lista las de la temporada actual.
-- Si falta alguna se usan las iniciales del nombre (en el idioma del cliente).
local KEYS = {
  -- Midnight T1
  [556] = { "POS", "Pit of Saron" },
  [161] = { "SR", "Skyreach" },
  [239] = { "SEAT", "Seat of the Triumvirate" },
  [402] = { "AA", "Algeth'ar Academy" },
  [557] = { "WS", "Windrunner Spire" },
  [558] = { "MT", "Magisters' Terrace" },
  [560] = { "MC", "Maisara Caverns" },
  [559] = { "NPX", "Nexus-Point Xenas" },
  -- Midnight T2
  [588] = { "AOF", "Altar of Fangs" },
  [587] = { "MR", "Murder Row" },
  [586] = { "DON", "Den of Nalorakk" },
  [584] = { "BV", "The Blinding Vale" },
  [585] = { "VSA", "Voidscar Arena" },
  [249] = { "KR", "Kings' Rest" },
  [250] = { "TOS", "Temple of Sethraliss" },
  [399] = { "RLP", "Ruby Life Pools" },
}

local SMALL_WORDS = {
  ["of"] = true, ["the"] = true, ["and"] = true,
  ["de"] = true, ["del"] = true, ["la"] = true, ["las"] = true, ["el"] = true, ["los"] = true, ["y"] = true,
}

function RB:KeyAbbr(key)
  if KEYS[key.map] then return KEYS[key.map][1] end
  if not key.name then return tostring(key.map) end
  local out = ""
  for word in key.name:gmatch("[^%s%-:,]+") do
    if not SMALL_WORDS[word:lower()] then
      -- primer carácter UTF-8 completo (puede llevar tilde)
      out = out .. (word:match("^[%z\1-\127\194-\244][\128-\191]*") or ""):upper()
    end
  end
  return out ~= "" and out or key.name
end

local function keyText(char)
  if not char.key then return "No key" end
  if (char.updated or 0) < RB:LastWeeklyReset() then return "? (outdated)" end
  return ("%s +%d"):format(RB:KeyAbbr(char.key), char.key.level)
end

local function tradeText(res)
  if res.ok then return "Trade All" end
  local failed, names = {}, {}
  for _, f in ipairs(res.fails) do failed[f[1]] = true end
  for _, f in ipairs(res.fails) do
    local id = f[1]
    -- si falla el mejor anillo/abalorio, "Rings"/"Trinkets" ya cubre el segundo
    local covered = (id == "FINGER2" and failed.FINGER1) or (id == "TRINKET2" and failed.TRINKET1)
    if not covered then names[#names + 1] = RB.CHECK_EN[id] or id end
  end
  if #names > 3 then return "Can't Trade" end
  return "Trade All Except " .. table.concat(names, ", ")
end

-- Roles que puede hacer cada clase (orden del mensaje: tank, heal, dps).
RB.ROLE_ORDER = { "TANK", "HEALER", "DAMAGER" }
local CAN_TANK = { WARRIOR = true, PALADIN = true, DEATHKNIGHT = true, DRUID = true, MONK = true, DEMONHUNTER = true }
local CAN_HEAL = { PALADIN = true, PRIEST = true, SHAMAN = true, DRUID = true, MONK = true, EVOKER = true }

function RB:CanPlayRole(char, role)
  if role == "TANK" then return CAN_TANK[char.class or ""] or false end
  if role == "HEALER" then return CAN_HEAL[char.class or ""] or false end
  return true
end

-- Roles marcados por el jugador; si nunca los ha tocado, el de su spec actual.
function RB:CharRoles(char)
  local set = {}
  if char.roles then
    for role in pairs(char.roles) do set[role] = true end
  elseif char.role then
    set[char.role] = true
  end
  return set
end

-- Los nombres pueden venir de otros jugadores (sync): fuera menciones y
-- formato de Discord para que nadie cuele un @everyone o un enlace.
local function safe(s)
  return (tostring(s or "?"):gsub("[@<>`*_~|\\]", ""))
end

local function charLine(char)
  local head = {}
  if E[char.faction or ""] then head[#head + 1] = E[char.faction] end
  local roles = RB:CharRoles(char)
  for _, role in ipairs(RB.ROLE_ORDER) do
    if roles[role] then head[#head + 1] = E[role] end
  end
  if CLASS_EMOJI[char.class or ""] then head[#head + 1] = CLASS_EMOJI[char.class] end
  head[#head + 1] = ("%s (%s)"):format(CLASS_EN[char.class or ""] or char.classLoc or "?", safe(char.name))

  local parts = { table.concat(head, " ") }
  if char.score then parts[#parts + 1] = ("%s %d"):format(E.score, char.score) end

  local res = RB:Evaluate(char)
  local gear = ("%s %d (%s)"):format(E.ilvl, char.ilvl or 0, tradeText(res))
  if res.noBank then gear = gear .. " " .. E.warn .. " bank not checked" end
  parts[#parts + 1] = gear
  parts[#parts + 1] = E.key .. " " .. keyText(char)
  return table.concat(parts, SEP)
end

local function accountHeader(tag, acc)
  if RB:IsValidDiscordId(acc.discordId) then
    return ("<@%s>"):format(acc.discordId)
  end
  return ("**%s**"):format(safe(tag))
end

-- Título fijo según el número de cuentas.
local TITLES = { "Solo Sign up", "Duo Sign up", "Trio Sign up" }

local ARMOR_OF = {
  WARRIOR = "Plate", PALADIN = "Plate", DEATHKNIGHT = "Plate",
  HUNTER = "Mail", SHAMAN = "Mail", EVOKER = "Mail",
  DRUID = "Leather", ROGUE = "Leather", MONK = "Leather", DEMONHUNTER = "Leather",
  MAGE = "Cloth", PRIEST = "Cloth", WARLOCK = "Cloth",
}
local ARMOR_ORDER = { "Plate", "Mail", "Leather", "Cloth" }

-- Máximo de personajes de una armadura en un grupo válido: un personaje por
-- cuenta, 1 tank + 1 healer + el resto DPS, según los roles de cada personaje.
-- Sin armadura (nil) devuelve >= 0 si existe algún grupo válido, -1 si no.
local NO = -1
local function maxStack(selection, armor)
  local dp = { [0] = { [0] = 0, [1] = NO }, [1] = { [0] = NO, [1] = NO } }
  for _, entry in ipairs(selection) do
    -- por rol: -1 no puede, 0 puede, 1 puede con esa armadura
    local best = { TANK = NO, HEALER = NO, DAMAGER = NO }
    for _, char in ipairs(entry.chars) do
      local v = (armor and ARMOR_OF[char.class or ""] == armor) and 1 or 0
      for role in pairs(RB:CharRoles(char)) do
        if best[role] and v > best[role] then best[role] = v end
      end
    end
    local nd = { [0] = { [0] = NO, [1] = NO }, [1] = { [0] = NO, [1] = NO } }
    for t = 0, 1 do
      for h = 0, 1 do
        local cur = dp[t][h]
        if cur >= 0 then
          local function relax(nt, nh, v)
            if v >= 0 and nt <= 1 and nh <= 1 and cur + v > nd[nt][nh] then nd[nt][nh] = cur + v end
          end
          relax(t + 1, h, best.TANK)
          relax(t, h + 1, best.HEALER)
          relax(t, h, best.DAMAGER)
        end
      end
    end
    dp = nd
  end
  return dp[1][1]
end

-- Sin grupo válido posible: cuántas cuentas tienen esa armadura (sin roles).
local function accountsWithArmor(selection, armor)
  local n = 0
  for _, entry in ipairs(selection) do
    for _, char in ipairs(entry.chars) do
      if ARMOR_OF[char.class or ""] == armor then
        n = n + 1
        break
      end
    end
  end
  return n
end

-- TT (4+ cuentas): el mayor apilamiento posible de cada armadura y las piedras.
local function ttSummary(selection)
  local lines = {}
  local parts = {}
  local validComp = maxStack(selection, nil) >= 0
  for _, armor in ipairs(ARMOR_ORDER) do
    local n = validComp and maxStack(selection, armor) or accountsWithArmor(selection, armor)
    parts[#parts + 1] = ("%s **x%d**"):format(armor, n)
  end
  lines[#lines + 1] = ":shield: Armor" .. SEP .. table.concat(parts, " · ")
  if not validComp then
    lines[#lines + 1] = E.warn .. " No valid comp (1 tank + 1 healer): armor counted without roles"
  end

  local keys = {}
  for _, entry in ipairs(selection) do
    for _, char in ipairs(entry.chars) do
      if char.key and (char.updated or 0) >= RB:LastWeeklyReset() then
        keys[#keys + 1] = char.key
      end
    end
  end
  table.sort(keys, function(a, b) return a.level > b.level end)
  local k = {}
  for _, key in ipairs(keys) do k[#k + 1] = ("%s +%d"):format(RB:KeyAbbr(key), key.level) end
  lines[#lines + 1] = E.key .. " Keys" .. SEP .. (#k > 0 and table.concat(k, " · ") or "No keys")
  return table.concat(lines, "\n")
end

local function groupHeader(selection)
  local n = #selection
  local header = ("**%s**"):format(TITLES[n] or "TT")
  if n >= 4 then
    -- TT: sin lista de personajes, pero se menciona a quien tenga Discord ID
    local names = {}
    for _, entry in ipairs(selection) do
      if RB:IsValidDiscordId(entry.acc.discordId) then
        names[#names + 1] = ("<@%s>"):format(entry.acc.discordId)
      end
    end
    if #names > 0 then header = header .. "\n" .. table.concat(names, " ") end
    header = header .. "\n" .. ttSummary(selection)
  end
  return header
end

-- selection = lista ordenada de { tag = , acc = , chars = { char, ... } }
-- Devuelve una lista de mensajes (cada uno < 2000 caracteres).
function RB:BuildMessages(selection)
  -- TT: menciones + resumen (armaduras y piedras), sin la lista de personajes
  if #selection >= 4 then return { groupHeader(selection) } end

  -- Solo: el mensaje lo pega uno mismo, mencionarse no aporta nada
  local solo = #selection == 1
  local blocks = {}
  for _, entry in ipairs(selection) do
    local lines = solo and {} or { accountHeader(entry.tag, entry.acc) }
    for _, char in ipairs(entry.chars) do
      lines[#lines + 1] = charLine(char)
    end
    blocks[#blocks + 1] = lines
  end

  local chunks, cur = {}, groupHeader(selection)
  local function push(text, sep)
    if cur ~= "" and #cur + #sep + #text > MAX_LEN then
      chunks[#chunks + 1] = cur
      cur = text
    else
      cur = cur == "" and text or (cur .. sep .. text)
    end
  end

  for _, lines in ipairs(blocks) do
    local block = table.concat(lines, "\n")
    if #block <= MAX_LEN then
      push(block, "\n\n")
    else
      push(lines[1], "\n\n")
      for i = 2, #lines do push(lines[i], "\n") end
    end
  end
  if cur ~= "" then chunks[#chunks + 1] = cur end
  return chunks
end

-- /rush keys: mazmorras de la temporada con su ID y abreviatura.
function RB:ListKeyMaps()
  local maps = C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapTable()
  if not maps or #maps == 0 then
    self:Print("No hay mazmorras de temporada disponibles todavía.")
    return
  end
  self:Print("Mazmorras de la temporada (ID · abreviatura · nombre):")
  for _, id in ipairs(maps) do
    local name = C_ChallengeMode.GetMapUIInfo(id)
    local known = KEYS[id]
    print(("  %d · %s · %s%s"):format(id, self:KeyAbbr({ map = id, name = name }),
      known and known[2] or name or "?", known and "" or " |cffff4040(falta en la tabla)|r"))
  end
end
