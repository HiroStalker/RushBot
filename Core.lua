local ADDON, RB = ...
_G.RushBot = RB

local v = C_AddOns.GetAddOnMetadata(ADDON, "Version")
RB.version = (v and not v:find("@", 1, true)) and v or "dev"
RB.DEFAULT_REF_ILVL = 311

local defaults = {
  settings = {
    refIlvl = RB.DEFAULT_REF_ILVL,
    discordPromptShown = false,
    myTag = nil,
  },
  -- accounts[battleTag] = { discordId, discordTs, chars = { [charKey] = char } }
  accounts = {},
  -- registros de autocalibración de la regla de tradeo
  calib = {},
  ui = {
    selected = {},
    onlyKey = false,
    onlyTrade = false,
  },
  minimap = {
    hide = false,
    angle = 225,
  },
}

local function applyDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      applyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

---------------------------------------------------------------------------
-- Eventos
---------------------------------------------------------------------------

RB.frame = CreateFrame("Frame")
RB.handlers = {}

function RB:On(event, fn)
  if not self.handlers[event] then
    -- algunos eventos cambian entre parches: no romper si no existe
    if not pcall(self.frame.RegisterEvent, self.frame, event) then return end
    self.handlers[event] = {}
  end
  table.insert(self.handlers[event], fn)
end

RB.frame:SetScript("OnEvent", function(_, event, ...)
  local list = RB.handlers[event]
  if not list then return end
  for i = 1, #list do list[i](event, ...) end
end)

---------------------------------------------------------------------------
-- Utilidades
---------------------------------------------------------------------------

function RB:Print(...)
  print("|cff33ff99RushBot|r:", ...)
end

function RB:Now()
  return GetServerTime()
end

-- Momento (server time) del último reinicio semanal.
function RB:LastWeeklyReset()
  local secs = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
  if not secs then return 0 end
  return self:Now() + secs - 7 * 24 * 3600
end

function RB:GetMyTag()
  local _, tag = BNGetInfo()
  if tag and tag ~= "" then
    self.db.settings.myTag = tag
    return tag
  end
  return self.db.settings.myTag
end

function RB:GetAccount(tag, create)
  if not tag then return nil end
  local acc = self.db.accounts[tag]
  if not acc and create then
    acc = { chars = {} }
    self.db.accounts[tag] = acc
  end
  return acc
end

function RB:GetMyAccount()
  return self:GetAccount(self:GetMyTag(), true)
end

function RB:MyCharKey()
  local name = UnitName("player")
  local realm = GetNormalizedRealmName()
  if not name or not realm then return nil end
  return name .. "-" .. realm
end

function RB:IsValidDiscordId(id)
  return type(id) == "string" and id:match("^%d+$") ~= nil and #id >= 17 and #id <= 20
end

---------------------------------------------------------------------------
-- Arranque
---------------------------------------------------------------------------

RB:On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  RushBotDB = RushBotDB or {}
  applyDefaults(RushBotDB, defaults)
  RB.db = RushBotDB
end)

RB:On("PLAYER_LOGIN", function()
  if not RB:GetMyTag() then
    RB:Print("No se pudo leer tu BattleTag (¿Battle.net desconectado?). Reintentaré al reconectar.")
  end
  RB:RequestScan(3)
  C_Timer.After(8, function()
    local acc = RB:GetMyAccount()
    if acc and not acc.discordId and not RB.db.settings.discordPromptShown then
      RB.db.settings.discordPromptShown = true
      RB.Config:Show(true)
    end
  end)
end)

RB:On("BN_CONNECTED", function()
  RB:RequestScan(2)
end)

---------------------------------------------------------------------------
-- Comandos
---------------------------------------------------------------------------

SLASH_RUSHBOT1 = "/rush"
SLASH_RUSHBOT2 = "/rushbot"
SlashCmdList.RUSHBOT = function(msg)
  local cmd = strtrim(msg or ""):lower()
  if cmd == "" then
    RB.UI:Toggle()
  elseif cmd == "config" then
    RB.Config:Show()
  elseif cmd == "scan" then
    if UnitLevel("player") < GetMaxLevelForPlayerExpansion() then
      RB:Print("Solo se escanean personajes a nivel máximo.")
      return
    end
    RB:ScanNow()
    RB:Print("Escaneo hecho. Abre el banco para actualizarlo también.")
  elseif cmd == "sync" then
    RB.UI:SyncNow()
    RB:Print(("Cola de envío: %d mensajes."):format(RB.Sync:QueueSize()))
  elseif cmd == "minimap" then
    RB.Minimap:ToggleShown()
  elseif cmd == "keys" then
    RB:ListKeyMaps()
  elseif cmd == "debug" then
    RB:CalibReport()
  elseif cmd == "debug clear" then
    wipe(RB.db.calib)
    RB:Print("Registros de calibración borrados.")
  else
    RB:Print("Comandos:")
    print("  /rush — abrir ventana")
    print("  /rush config — Discord ID e ilvl de referencia")
    print("  /rush scan — reescanear este personaje")
    print("  /rush sync — sincronizar ahora")
    print("  /rush minimap — mostrar/ocultar botón del minimapa")
    print("  /rush keys — mazmorras de la temporada (ID y abreviatura)")
    print("  /rush debug — resultados de la autocalibración de tradeo")
  end
end

function RushBot_OnAddonCompartmentClick()
  RB.UI:Toggle()
end
