local _, RB = ...

local GetItemInfoInstant = C_Item.GetItemInfoInstant or GetItemInfoInstant
local GetSpecialization = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
local GetSpecializationInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo

local ITEM_CLASS_ARMOR = Enum.ItemClass.Armor
local ITEM_CLASS_WEAPON = Enum.ItemClass.Weapon
local WAND = (Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Wand) or 19

local ARMOR_SUB = Enum.ItemArmorSubclass or { Cloth = 1, Leather = 2, Mail = 3, Plate = 4 }
local CLASS_ARMOR = {
  WARRIOR = ARMOR_SUB.Plate, PALADIN = ARMOR_SUB.Plate, DEATHKNIGHT = ARMOR_SUB.Plate,
  HUNTER = ARMOR_SUB.Mail, SHAMAN = ARMOR_SUB.Mail, EVOKER = ARMOR_SUB.Mail,
  DRUID = ARMOR_SUB.Leather, ROGUE = ARMOR_SUB.Leather, MONK = ARMOR_SUB.Leather, DEMONHUNTER = ARMOR_SUB.Leather,
  MAGE = ARMOR_SUB.Cloth, PRIEST = ARMOR_SUB.Cloth, WARLOCK = ARMOR_SUB.Cloth,
}

-- Slots de armadura: solo cuenta el tipo de armadura de la clase.
local ARMOR_SLOTS = {
  INVTYPE_HEAD = "HEAD", INVTYPE_SHOULDER = "SHOULDER", INVTYPE_CHEST = "CHEST", INVTYPE_ROBE = "CHEST",
  INVTYPE_WRIST = "WRIST", INVTYPE_HAND = "HANDS", INVTYPE_WAIST = "WAIST", INVTYPE_LEGS = "LEGS",
  INVTYPE_FEET = "FEET",
}

local OTHER_SLOTS = {
  INVTYPE_NECK = "NECK", INVTYPE_CLOAK = "BACK", INVTYPE_FINGER = "FINGER", INVTYPE_TRINKET = "TRINKET",
  INVTYPE_2HWEAPON = "TWOHAND", INVTYPE_RANGED = "TWOHAND",
  INVTYPE_WEAPON = "ONEHAND", INVTYPE_WEAPONMAINHAND = "MAINHAND", INVTYPE_WEAPONOFFHAND = "OFFWEAPON",
  INVTYPE_SHIELD = "SHIELD", INVTYPE_HOLDABLE = "OFFHAND",
}

function RB:Categorize(equipLoc, classID, subclassID)
  local cat = ARMOR_SLOTS[equipLoc]
  if cat then
    if classID ~= ITEM_CLASS_ARMOR or subclassID ~= self.myArmor then return nil end
    return cat
  end
  if equipLoc == "INVTYPE_RANGEDRIGHT" then
    if classID == ITEM_CLASS_WEAPON and subclassID == WAND then return "MAINHAND" end
    return "TWOHAND"
  end
  return OTHER_SLOTS[equipLoc]
end

-- gear[cat] = { ilvl1, ilvl2, src1, src2 }  (los dos mejores de esa categoría)
local function add(gear, cat, ilvl, src)
  local t = gear[cat]
  if not t then
    t = { 0, 0, "", "" }
    gear[cat] = t
  end
  if ilvl > t[1] then
    t[2], t[4] = t[1], t[3]
    t[1], t[3] = ilvl, src
  elseif ilvl > t[2] then
    t[2], t[4] = ilvl, src
  end
end
RB.AddGear = add

-- Devuelve cat, ilvl si el objeto en esa ubicación cuenta para la regla de tradeo.
function RB:InspectLocation(loc)
  if not C_Item.DoesItemExist(loc) then return nil end
  local itemID = C_Item.GetItemID(loc)
  if not itemID then return nil end
  local _, _, _, equipLoc, _, classID, subclassID = GetItemInfoInstant(itemID)
  if not equipLoc or equipLoc == "" then return nil end
  local cat = self:Categorize(equipLoc, classID, subclassID)
  if not cat then return nil end
  -- un BoE sin ligar no es "tuyo" a efectos de la regla
  if not C_Item.IsBound(loc) then return nil end
  local ilvl = C_Item.GetCurrentItemLevel(loc)
  if not ilvl or ilvl <= 0 then return nil end
  return cat, ilvl
end

local function scanContainer(bag, gear, src, onItem)
  for slot = 1, C_Container.GetContainerNumSlots(bag) do
    local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
    local cat, ilvl = RB:InspectLocation(loc)
    if cat then
      add(gear, cat, ilvl, src)
      if onItem then onItem(loc, bag, slot, cat, ilvl) end
    end
  end
end

local function bagList()
  local list = {}
  local n = (Constants.InventoryConstants and Constants.InventoryConstants.NumBagSlots) or NUM_BAG_SLOTS or 4
  for bag = 0, n do list[#list + 1] = bag end
  return list
end

local function bankList()
  local list = {}
  if Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1 then
    for i = 1, 10 do
      local id = Enum.BagIndex["CharacterBankTab_" .. i]
      if not id then break end
      list[#list + 1] = id
    end
  else
    list[1] = BANK_CONTAINER or -1
    local first = (NUM_BAG_SLOTS or 4) + 1
    for bag = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do list[#list + 1] = bag end
  end
  return list
end

local function readKeystone()
  if not C_MythicPlus then return nil end
  local mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
  local level = C_MythicPlus.GetOwnedKeystoneLevel()
  if not mapID or not level or level <= 0 then return nil end
  local name = C_ChallengeMode.GetMapUIInfo(mapID)
  return { map = mapID, level = level, name = name }
end

local function readScore()
  if not (C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore) then return nil end
  local score = C_ChallengeMode.GetOverallDungeonScore()
  if not score or score <= 0 then return nil end
  return math.floor(score)
end

local function readWatermarks()
  if not (C_ItemUpgrade and C_ItemUpgrade.GetHighWatermarkForSlot and Enum.ItemRedundancySlot) then return nil end
  local wm = {}
  for name, id in pairs(Enum.ItemRedundancySlot) do
    local charHigh = C_ItemUpgrade.GetHighWatermarkForSlot(id)
    if charHigh and charHigh > 0 then wm[name] = charHigh end
  end
  return wm
end

-- Solo cambia "updated" (y se sincroniza) si cambió algo que se comparte,
-- o si el dato es de antes del reinicio semanal.
function RB:CommitChar(char, key, prevSig, prevUpdated)
  if prevUpdated and prevUpdated >= self:LastWeeklyReset() and self:CharSignature(char) == prevSig then
    char.updated = prevUpdated
    return
  end
  char.updated = self:Now()
  char.src, char.via = nil, nil -- dato propio
  if self.Sync then self.Sync:LocalChanged(self:GetMyTag(), key) end
end

function RB:GetMyChar()
  local acc = self:GetMyAccount()
  local key = self:MyCharKey()
  if not acc or not key then return nil end
  local char = acc.chars[key]
  if not char then
    char = {}
    acc.chars[key] = char
  end
  return char, key, acc
end

---------------------------------------------------------------------------
-- Escaneo principal (equipado + bolsas + piedra)
---------------------------------------------------------------------------

function RB:ScanNow()
  if not self.db then return end
  if UnitLevel("player") < GetMaxLevelForPlayerExpansion() then return end
  local char, key, acc = self:GetMyChar()
  if not char then return end

  local _, classFile = UnitClass("player")
  self.myArmor = CLASS_ARMOR[classFile]

  local prevSig, prevUpdated = self:CharSignature(char), char.updated

  -- estado previo, para la autocalibración
  self:CalibBeforeScan(char)

  local gear = {}
  for slot = INVSLOT_FIRST_EQUIPPED, INVSLOT_LAST_EQUIPPED do
    local loc = ItemLocation:CreateFromEquipmentSlot(slot)
    local cat, ilvl = self:InspectLocation(loc)
    if cat then add(gear, cat, ilvl, "E") end
  end
  for _, bag in ipairs(bagList()) do
    scanContainer(bag, gear, "B", function(...) RB:CalibOnBagItem(...) end)
  end
  self:CalibAfterScan()

  local classLoc = UnitClass("player")
  local specIndex = GetSpecialization()
  local specID, specName, role
  if specIndex then
    local id, name, _, _, specRole = GetSpecializationInfo(specIndex)
    specID, specName, role = id, name, specRole
  end
  local _, equippedIlvl = GetAverageItemLevel()

  char.name = UnitName("player")
  char.realm = GetRealmName()
  char.class = classFile
  char.classLoc = classLoc
  char.spec = specName
  char.specID = specID
  char.role = role
  char.faction = UnitFactionGroup("player")
  char.score = readScore()
  char.ilvl = math.floor(equippedIlvl or 0)
  char.gear = gear
  char.weaponMode = nil -- obsoleto: las armas se evalúan por clase
  char.key = readKeystone()
  char.watermark = readWatermarks()
  self:CommitChar(char, key, prevSig, prevUpdated)

  if self.UI then self.UI:RefreshIfShown() end
end

---------------------------------------------------------------------------
-- Banco (solo legible con el banco abierto)
---------------------------------------------------------------------------

function RB:ScanBank()
  if not self.db or not self.bankOpen then return end
  local char, key = self:GetMyChar()
  if not char or not char.updated then return end -- antes, el escaneo normal
  local prevSig, prevUpdated = self:CharSignature(char), char.updated
  local _, classFile = UnitClass("player")
  self.myArmor = CLASS_ARMOR[classFile]

  local gear, anySlots = {}, false
  for _, bag in ipairs(bankList()) do
    if C_Container.GetContainerNumSlots(bag) > 0 then anySlots = true end
    scanContainer(bag, gear, "K")
  end
  -- si no hay pestañas compradas también cuenta como leído (banco vacío)
  char.bank = gear
  char.bankScanned = self:Now()
  if not anySlots then char.bankEmpty = true else char.bankEmpty = nil end
  self:CommitChar(char, key, prevSig, prevUpdated)
  if self.UI then self.UI:RefreshIfShown() end
end

---------------------------------------------------------------------------
-- Disparadores
---------------------------------------------------------------------------

local scanPending = false
function RB:RequestScan(delay)
  if scanPending then return end
  scanPending = true
  C_Timer.After(delay or 1, function()
    scanPending = false
    RB:ScanNow()
    if RB.bankOpen then RB:ScanBank() end
  end)
end

RB:On("BAG_UPDATE_DELAYED", function() RB:RequestScan(1) end)
RB:On("PLAYER_EQUIPMENT_CHANGED", function() RB:RequestScan(1) end)
RB:On("PLAYER_SPECIALIZATION_CHANGED", function(_, unit) if unit == "player" then RB:RequestScan(1) end end)
RB:On("CHALLENGE_MODE_COMPLETED", function() RB:RequestScan(3) end)
RB:On("ITEM_UPGRADE_MASTER_UPDATE", function() RB:RequestScan(1) end)

local function onBankOpen()
  RB.bankOpen = true
  -- los contenidos del banco pueden tardar un instante en estar disponibles
  C_Timer.After(0.5, function() RB:ScanBank() end)
end

local function onBankClose()
  RB.bankOpen = false
end

RB:On("BANKFRAME_OPENED", onBankOpen)
RB:On("BANKFRAME_CLOSED", onBankClose)

local BANKER = Enum.PlayerInteractionType and Enum.PlayerInteractionType.Banker
RB:On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
  if BANKER and kind == BANKER then onBankOpen() end
end)
RB:On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
  if BANKER and kind == BANKER then onBankClose() end
end)
