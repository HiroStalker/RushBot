local _, RB = ...

local Config = {}
RB.Config = Config

local function label(parent, text, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
  fs:SetText(text)
  fs:SetJustifyH("LEFT")
  return fs
end

local function input(parent, width)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width, 22)
  eb:SetAutoFocus(false)
  eb:SetScript("OnEscapePressed", eb.ClearFocus)
  return eb
end

function Config:Create()
  local f = CreateFrame("Frame", "RushBotConfigFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(440, 300)
  f:SetPoint("CENTER", 0, 60)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "RushBotConfigFrame")

  local title = label(f, "RushBot · Configuración", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)

  f.intro = label(f, "", "GameFontHighlightSmall")
  f.intro:SetPoint("TOPLEFT", 16, -34)
  f.intro:SetWidth(408)

  local idLabel = label(f, "Tu Discord ID")
  idLabel:SetPoint("TOPLEFT", 16, -78)
  f.idBox = input(f, 220)
  f.idBox:SetPoint("TOPLEFT", idLabel, "BOTTOMLEFT", 6, -4)
  f.idBox:SetMaxLetters(20)

  local help = label(f,
    "Discord → Ajustes → Avanzado → activa Modo desarrollador.\n" ..
    "Luego clic derecho en tu nombre → Copiar ID de usuario.\n" ..
    "Es un número de 17-20 cifras. Así te mencionarán con @.",
    "GameFontDisableSmall")
  help:SetPoint("TOPLEFT", f.idBox, "BOTTOMLEFT", -6, -6)
  help:SetWidth(408)

  local refLabel = label(f, "Ilvl de referencia (tradea si tiene este ilvl o más en cada slot)")
  refLabel:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -14)
  refLabel:SetWidth(408)
  f.refBox = input(f, 60)
  f.refBox:SetPoint("TOPLEFT", refLabel, "BOTTOMLEFT", 6, -4)
  f.refBox:SetNumeric(true)
  f.refBox:SetMaxLetters(4)

  f.status = label(f, "", "GameFontRedSmall")
  f.status:SetPoint("BOTTOMLEFT", 16, 16)
  f.status:SetWidth(260)

  local save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  save:SetSize(100, 22)
  save:SetPoint("BOTTOMRIGHT", -14, 12)
  save:SetText("Guardar")
  save:SetScript("OnClick", function() Config:Save() end)
  f.idBox:SetScript("OnEnterPressed", function() Config:Save() end)
  f.refBox:SetScript("OnEnterPressed", function() Config:Save() end)

  self.frame = f
end

function Config:Show(firstRun)
  if not self.frame then self:Create() end
  local f = self.frame
  local acc = RB:GetMyAccount()
  f.intro:SetText(firstRun
    and "¡Bienvenido a RushBot! Pon tu Discord ID para que te mencionen en los mensajes. Puedes hacerlo luego con /rush config."
    or ("Cuenta: %s"):format(RB:GetMyTag() or "BattleTag desconocida"))
  f.idBox:SetText(acc and acc.discordId or "")
  f.refBox:SetText(tostring(RB.db.settings.refIlvl or RB.DEFAULT_REF_ILVL))
  f.status:SetText("")
  f:Show()
end

function Config:Save()
  local f = self.frame
  local acc = RB:GetMyAccount()
  local id = strtrim(f.idBox:GetText() or "")
  local ref = tonumber(f.refBox:GetText())

  if id ~= "" and not RB:IsValidDiscordId(id) then
    f.status:SetText("Discord ID no válido: solo números, 17-20 cifras.")
    return
  end
  if not ref or ref <= 0 then
    f.status:SetText("Ilvl de referencia no válido.")
    return
  end
  if not acc then
    f.status:SetText("No se pudo leer tu BattleTag. Reintenta con Battle.net conectado.")
    return
  end

  local newId = id ~= "" and id or nil
  if acc.discordId ~= newId then
    acc.discordId = newId
    acc.discordTs = RB:Now()
    acc.discordSrc = nil
    RB.Sync:LocalChanged(RB:GetMyTag(), "")
  end
  RB.db.settings.refIlvl = ref
  f:Hide()
  RB:Print("Configuración guardada.")
  if RB.UI then RB.UI:RefreshIfShown() end
end
