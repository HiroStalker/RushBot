local ADDON, RB = ...

-- Botón en el minimapa (sin LibDBIcon: el addon no usa librerías externas).

local MM = {}
RB.Minimap = MM

local ICON = "Interface\\AddOns\\RushBot\\Media\\icon"

local function updatePosition(btn)
  local angle = math.rad(RB.db.minimap.angle or 225)
  local radius = (Minimap:GetWidth() / 2) + 10
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function onDragUpdate(btn)
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  RB.db.minimap.angle = math.deg(math.atan2(py - my, px - mx)) % 360
  updatePosition(btn)
end

function MM:Create()
  if self.button then return end
  local btn = CreateFrame("Button", "RushBotMinimapButton", Minimap)
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(24, 24)
  bg:SetPoint("CENTER")

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(ICON)
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER")
  btn.icon = icon

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  btn:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      RB.Config:Show()
    else
      RB.UI:Toggle()
    end
  end)
  btn:SetScript("OnDragStart", function(b)
    b:SetScript("OnUpdate", onDragUpdate)
  end)
  btn:SetScript("OnDragStop", function(b)
    b:SetScript("OnUpdate", nil)
  end)
  btn:SetScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_LEFT")
    GameTooltip:AddLine("RushBot")
    GameTooltip:AddLine("|cffffffffClic izquierdo:|r abrir ventana", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffClic derecho:|r configuración", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffArrastrar:|r mover", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  self.button = btn
  updatePosition(btn)
end

function MM:Refresh()
  if RB.db.minimap.hide then
    if self.button then self.button:Hide() end
  else
    self:Create()
    self.button:Show()
  end
end

function MM:ToggleShown()
  RB.db.minimap.hide = not RB.db.minimap.hide
  self:Refresh()
  if RB.db.minimap.hide then
    RB:Print("Botón del minimapa oculto. Usa /rush minimap para mostrarlo.")
  end
end

RB:On("PLAYER_LOGIN", function()
  MM:Refresh()
end)
