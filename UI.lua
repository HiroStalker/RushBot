local _, RB = ...

local UI = {}
RB.UI = UI

local ROW_H = 22
local ALERT = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:14|t"

local function ago(ts)
  if not ts then return "nunca" end
  local s = RB:Now() - ts
  if s < 3600 then return ("%dm"):format(math.max(0, math.floor(s / 60))) end
  if s < 86400 then return ("%dh"):format(math.floor(s / 3600)) end
  return ("%dd"):format(math.floor(s / 86400))
end

local function classColored(char, text)
  local c = char.class and RAID_CLASS_COLORS[char.class]
  return c and c:WrapTextInColorCode(text) or text
end

local ROLE_NAMES = { TANK = "Tank", HEALER = "Heal", DAMAGER = "DPS" }

-- Coordenadas de los iconos de rol en UI-LFG-ICON-ROLES (rejilla de 67px en 256px).
local function roleTexCoords(role)
  if GetTexCoordsForRole then return GetTexCoordsForRole(role) end
  local g = 67 / 256
  local x, y = 2, 2
  if role == "TANK" then x, y = 1, 2 elseif role == "HEALER" then x, y = 2, 1 end
  return (x - 1) * g, x * g, (y - 1) * g, y * g
end

local function selKey(tag, charKey)
  return tag .. "|" .. charKey
end

local function fontString(parent, template, width, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
  fs:SetWidth(width)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

---------------------------------------------------------------------------
-- Datos para la lista
---------------------------------------------------------------------------

local function sortedAccounts()
  local myTag = RB:GetMyTag()
  local tags = {}
  for tag in pairs(RB.db.accounts) do tags[#tags + 1] = tag end
  table.sort(tags, function(a, b)
    if a == myTag then return true end
    if b == myTag then return false end
    return a:lower() < b:lower()
  end)
  return tags
end

function UI:BuildEntries()
  local search = (self.frame.search:GetText() or ""):lower()
  local onlyKey = RB.db.ui.onlyKey
  local entries = {}
  for _, tag in ipairs(sortedAccounts()) do
    local acc = RB.db.accounts[tag]
    local tagMatch = search == "" or tag:lower():find(search, 1, true)
    local chars = {}
    for charKey, char in pairs(acc.chars) do
      local nameMatch = tagMatch or (char.name or ""):lower():find(search, 1, true)
      if nameMatch and (not onlyKey or char.key) and char.updated then
        chars[#chars + 1] = { key = charKey, char = char }
      end
    end
    if #chars > 0 then
      table.sort(chars, function(a, b) return (a.char.ilvl or 0) > (b.char.ilvl or 0) end)
      entries[#entries + 1] = { kind = "acc", tag = tag, acc = acc, chars = chars }
      for _, c in ipairs(chars) do
        entries[#entries + 1] = { kind = "char", tag = tag, acc = acc, key = c.key, char = c.char }
      end
    end
  end
  return entries
end

---------------------------------------------------------------------------
-- Filas
---------------------------------------------------------------------------

local function rowOnEnter(row)
  local e = row.entry
  if not e or e.kind ~= "char" then return end
  local char = e.char
  local ref = RB.db.settings.refIlvl or RB.DEFAULT_REF_ILVL
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(classColored(char, ("%s - %s"):format(char.name or "?", char.realm or "?")))
  GameTooltip:AddLine(("Mejor ilvl por slot (ref %d)"):format(ref), 1, 0.82, 0)
  for _, chk in ipairs(RB:Checks(char)) do
    local okc = chk[2] >= ref
    GameTooltip:AddDoubleLine(RB.CHECK_ES[chk[1]] or chk[1], chk[2] > 0 and tostring(chk[2]) or "vacío",
      1, 1, 1, okc and 0.2 or 1, okc and 1 or 0.2, 0.2)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddDoubleLine("Actualizado", "hace " .. ago(char.updated), 0.7, 0.7, 0.7, 1, 1, 1)
  local origin = (char.src == "direct" and "directo") or (char.src == "relay" and ("reenviado por " .. (char.via or "?")))
    or "este PC"
  GameTooltip:AddDoubleLine("Origen", origin, 0.7, 0.7, 0.7, 1, 1, 1)
  GameTooltip:AddDoubleLine("Banco leído", char.bankScanned and ("hace " .. ago(char.bankScanned)) or "nunca (abre el banco)",
    0.7, 0.7, 0.7, 1, 1, 1)
  GameTooltip:Show()
end

local function rowOnLeave()
  GameTooltip:Hide()
end

function UI:CreateRow(i)
  local content = self.frame.content
  local row = CreateFrame("Button", nil, content)
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  row:SetPoint("RIGHT", content, "RIGHT")
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetColorTexture(1, 1, 1, 0.05)

  row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.check:SetSize(20, 20)
  row.check:SetScript("OnClick", function(cb) UI:OnCheck(row.entry, cb:GetChecked()) end)

  row.name = fontString(row, "GameFontHighlight", 170)
  row.info = fontString(row, nil, 150)
  row.keyText = fontString(row, nil, 150)
  row.status = fontString(row, nil, 120)
  row.age = fontString(row, "GameFontDisableSmall", 50, "RIGHT")

  row.info:SetPoint("LEFT", row, "LEFT", 222, 0)
  row.keyText:SetPoint("LEFT", row, "LEFT", 376, 0)
  row.status:SetPoint("LEFT", row, "LEFT", 580, 0)
  row.age:SetPoint("RIGHT", row, "RIGHT", -4, 0)

  row.roles = {}
  for i, role in ipairs(RB.ROLE_ORDER) do
    local b = CreateFrame("Button", nil, row)
    b:SetSize(18, 18)
    b:SetPoint("LEFT", row, "LEFT", 510 + (i - 1) * 21, 0)
    b.role = role
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-ROLES")
    b.icon:SetTexCoord(roleTexCoords(role))
    b:SetScript("OnClick", function() UI:ToggleRole(row.entry, role) end)
    b:SetScript("OnEnter", function(btn)
      GameTooltip:SetOwner(btn, "ANCHOR_TOP")
      GameTooltip:AddLine(ROLE_NAMES[role])
      if btn.editable then
        GameTooltip:AddLine("Clic para marcar/desmarcar", 0.7, 0.7, 0.7)
      else
        GameTooltip:AddLine("Solo lo cambia el dueño de la cuenta", 0.7, 0.7, 0.7)
      end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", rowOnLeave)
    row.roles[i] = b
  end

  row:SetScript("OnEnter", rowOnEnter)
  row:SetScript("OnLeave", rowOnLeave)
  row:SetScript("OnClick", function() row.check:Click() end)
  return row
end

function UI:FillRoles(row, e)
  local char = e.char
  local active = RB:CharRoles(char)
  local editable = e.tag == RB:GetMyTag()
  for _, b in ipairs(row.roles) do
    if RB:CanPlayRole(char, b.role) then
      b.editable = editable
      b.icon:SetDesaturated(not active[b.role])
      b.icon:SetAlpha(active[b.role] and 1 or 0.3)
      b:Show()
    else
      b:Hide()
    end
  end
end

function UI:ToggleRole(e, role)
  if not e or e.kind ~= "char" or e.tag ~= RB:GetMyTag() then return end
  local char = e.char
  -- la primera vez se parte del rol de la spec actual
  local roles = RB:CharRoles(char)
  roles[role] = not roles[role] or nil
  char.roles = roles
  char.rolesTs = RB:Now()
  RB.Sync:LocalChanged(e.tag, e.key)
  self:Refresh()
end

function UI:FillRow(row, e)
  row.entry = e
  local sel = RB.db.ui.selected
  if e.kind == "acc" then
    row.bg:Show()
    row.check:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.name:SetPoint("LEFT", row, "LEFT", 26, 0)
    row.name:SetWidth(360)
    row.name:SetText("|cffffd100" .. e.tag .. "|r")
    local all = true
    for _, c in ipairs(e.chars) do
      if not sel[selKey(e.tag, c.key)] then all = false break end
    end
    row.check:SetChecked(all)
    row.info:SetText("")
    row.keyText:SetText("")
    row.status:SetText(RB:IsValidDiscordId(e.acc.discordId) and "|cff7289daDiscord OK|r"
      or ("|cff999999" .. ALERT .. " sin Discord ID|r"))
    row.age:SetText("")
    for _, b in ipairs(row.roles) do b:Hide() end
    return
  end

  local char = e.char
  row.bg:Hide()
  self:FillRoles(row, e)
  row.check:SetPoint("LEFT", row, "LEFT", 22, 0)
  row.name:SetPoint("LEFT", row, "LEFT", 46, 0)
  row.name:SetWidth(170)
  row.check:SetChecked(sel[selKey(e.tag, e.key)] and true or false)
  row.name:SetText(classColored(char, char.name or "?") .. " |cff888888" .. (char.realm or "") .. "|r")
  local score = char.score and (" · |cffff8000%d|r"):format(char.score) or ""
  row.info:SetText(("%s %s · %d%s"):format(char.spec or "", char.classLoc or "", char.ilvl or 0, score))

  if not char.key then
    row.keyText:SetText("|cff888888sin piedra|r")
  elseif (char.updated or 0) < RB:LastWeeklyReset() then
    row.keyText:SetText("|cff888888¿? (antes del reset)|r")
  else
    row.keyText:SetText(("%s |cffffd100+%d|r"):format(RB:KeyAbbr(char.key), char.key.level))
  end

  local res = RB:Evaluate(char)
  local status = res.ok and "|cff33ff33Tradea todo|r" or ("|cffff4040No tradea (%d)|r"):format(#res.fails)
  if res.noBank then status = status .. " " .. ALERT end
  row.status:SetText(status)
  row.age:SetText(ago(char.updated))
end

function UI:OnCheck(e, checked)
  if not e then return end
  local sel = RB.db.ui.selected
  if e.kind == "acc" then
    for _, c in ipairs(e.chars) do sel[selKey(e.tag, c.key)] = checked or nil end
  else
    sel[selKey(e.tag, e.key)] = checked or nil
  end
  self:Refresh()
end

---------------------------------------------------------------------------
-- Ventana principal
---------------------------------------------------------------------------

local function button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

function UI:Create()
  local f = CreateFrame("Frame", "RushBotMainFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(840, 480)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:Hide()
  tinsert(UISpecialFrames, "RushBotMainFrame")

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)
  title:SetText("RushBot")

  f.search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
  f.search:SetSize(200, 20)
  f.search:SetPoint("TOPLEFT", 20, -32)
  f.search:SetAutoFocus(false)
  f.search:HookScript("OnTextChanged", function() UI:Refresh() end)

  f.onlyKey = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  f.onlyKey:SetSize(22, 22)
  f.onlyKey:SetPoint("LEFT", f.search, "RIGHT", 16, 0)
  f.onlyKey:SetScript("OnClick", function(cb)
    RB.db.ui.onlyKey = cb:GetChecked() and true or false
    UI:Refresh()
  end)
  local okLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  okLabel:SetPoint("LEFT", f.onlyKey, "RIGHT", 2, 0)
  okLabel:SetText("Solo con piedra")

  f.refText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.refText:SetPoint("TOPRIGHT", -20, -36)

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 12, -60)
  scroll:SetPoint("BOTTOMRIGHT", -32, 44)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(780, 1)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(s, w) content:SetWidth(w) end)
  f.scroll, f.content = scroll, content

  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  f.empty:SetPoint("CENTER", scroll, "CENTER")
  f.empty:SetText("Sin datos todavía. Entra con tus personajes (nivel máximo) y abre el banco.")

  local all = button(f, "Todo", 70, function() UI:SelectAll(true) end)
  all:SetPoint("BOTTOMLEFT", 14, 12)
  local none = button(f, "Nada", 70, function() UI:SelectAll(false) end)
  none:SetPoint("LEFT", all, "RIGHT", 6, 0)

  local gen = button(f, "Generar mensaje", 140, function() UI:Generate() end)
  gen:SetPoint("BOTTOMRIGHT", -14, 12)
  local cfg = button(f, "Config", 80, function() RB.Config:Show() end)
  cfg:SetPoint("RIGHT", gen, "LEFT", -6, 0)
  local scan = button(f, "Escanear", 90, function() RB:ScanNow() end)
  scan:SetPoint("RIGHT", cfg, "LEFT", -6, 0)
  local sync = button(f, "Sincronizar", 100, function() UI:SyncNow() end)
  sync:SetPoint("RIGHT", scan, "LEFT", -6, 0)

  f.selCount = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.selCount:SetPoint("LEFT", none, "RIGHT", 12, 0)

  f:SetScript("OnShow", function() UI:Refresh() end)
  self.rows = {}
  self.frame = f
end

function UI:Refresh()
  local f = self.frame
  if not f then return end
  f.onlyKey:SetChecked(RB.db.ui.onlyKey)
  f.refText:SetText(("Ilvl ref: |cffffffff%d|r"):format(RB.db.settings.refIlvl or RB.DEFAULT_REF_ILVL))

  local entries = self:BuildEntries()
  self.entries = entries
  for i, e in ipairs(entries) do
    local row = self.rows[i] or self:CreateRow(i)
    self.rows[i] = row
    self:FillRow(row, e)
    row:Show()
  end
  for i = #entries + 1, #self.rows do self.rows[i]:Hide() end
  f.content:SetHeight(math.max(1, #entries * ROW_H))
  f.empty:SetShown(#entries == 0)

  local n = 0
  for _, e in ipairs(entries) do
    if e.kind == "char" and RB.db.ui.selected[selKey(e.tag, e.key)] then n = n + 1 end
  end
  f.selCount:SetText(("%d seleccionados"):format(n))
end

function UI:RefreshIfShown()
  if self.frame and self.frame:IsShown() then self:Refresh() end
end

function UI:SelectAll(on)
  local sel = RB.db.ui.selected
  for _, e in ipairs(self.entries or {}) do
    if e.kind == "char" then sel[selKey(e.tag, e.key)] = on or nil end
  end
  self:Refresh()
end

function UI:SyncNow()
  RB.Sync:HelloAll()
  if RB.Sync:CanSend() then
    RB:Print("Sincronizando con hermandad, grupo y amigos de Battle.net...")
  else
    RB:Print("En combate o dentro de una instancia: se sincronizará al salir.")
  end
end

function UI:Toggle()
  if not RB.db then return end
  if not self.frame then self:Create() end
  self.frame:SetShown(not self.frame:IsShown())
end

---------------------------------------------------------------------------
-- Mensaje
---------------------------------------------------------------------------

function UI:Generate()
  local sel = RB.db.ui.selected
  local selection, current = {}, nil
  for _, e in ipairs(self.entries or {}) do
    if e.kind == "acc" then
      current = { tag = e.tag, acc = e.acc, chars = {} }
    elseif sel[selKey(e.tag, e.key)] then
      if #current.chars == 0 then selection[#selection + 1] = current end
      table.insert(current.chars, e.char)
    end
  end
  if #selection == 0 then
    RB:Print("No hay personajes seleccionados.")
    return
  end
  self:ShowMessages(RB:BuildMessages(selection))
end

function UI:CreateMessageFrame()
  local f = CreateFrame("Frame", "RushBotMessageFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(600, 380)
  f:SetPoint("CENTER", 0, -20)
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "RushBotMessageFrame")

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)
  title:SetText("RushBot · Mensaje para Discord")

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hint:SetPoint("TOPLEFT", 16, -32)
  hint:SetText("Ctrl+C para copiar y pega en Discord.")

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 14, -52)
  scroll:SetPoint("BOTTOMRIGHT", -32, 44)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(540)
  edit:SetAutoFocus(false)
  edit:SetScript("OnEscapePressed", function() f:Hide() end)
  -- solo lectura: si el usuario escribe, se restaura el texto
  edit:SetScript("OnTextChanged", function(eb, userInput)
    if userInput then
      eb:SetText(UI.msgChunks[UI.msgPage] or "")
      eb:HighlightText()
    end
  end)
  edit:SetScript("OnEditFocusGained", function(eb) eb:HighlightText() end)
  scroll:SetScrollChild(edit)
  scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
  f.edit = edit

  f.prev = button(f, "< Anterior", 100, function() UI:ShowPage(UI.msgPage - 1) end)
  f.prev:SetPoint("BOTTOMLEFT", 14, 12)
  f.next = button(f, "Siguiente >", 100, function() UI:ShowPage(UI.msgPage + 1) end)
  f.next:SetPoint("BOTTOMRIGHT", -14, 12)
  f.page = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.page:SetPoint("BOTTOM", 0, 17)

  self.msgFrame = f
end

function UI:ShowMessages(chunks)
  if not self.msgFrame then self:CreateMessageFrame() end
  self.msgChunks = chunks
  self.msgFrame:Show()
  self:ShowPage(1)
end

function UI:ShowPage(n)
  local f, chunks = self.msgFrame, self.msgChunks
  n = math.max(1, math.min(n, #chunks))
  self.msgPage = n
  f.edit:SetText(chunks[n])
  f.edit:SetFocus()
  f.edit:HighlightText()
  f.page:SetText(("Mensaje %d/%d"):format(n, #chunks))
  f.prev:SetEnabled(n > 1)
  f.next:SetEnabled(n < #chunks)
end
