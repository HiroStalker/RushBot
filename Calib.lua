local _, RB = ...

-- Autocalibración de la regla de tradeo.
-- Cuando entra en las bolsas un objeto equipable nuevo poco después de un
-- loot, se compara lo que predecía la regla con lo que dice el tooltip
-- ("Puedes comerciar con este objeto..."). Así sabremos cómo funcionan de
-- verdad anillos, abalorios y armas.

local MAX_RECORDS = 200
local LOOT_WINDOW = 180

local seen = {}
local ready = false
local lootUntil = 0
local prevCombined, prevWatermark, pending

local tradePattern
local function getTradePattern()
  if tradePattern then return tradePattern end
  local s = BIND_TRADE_TIME_REMAINING
  if not s then return nil end
  s = s:gsub("%%s", "\001")
  s = s:gsub("[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%0")
  s = s:gsub("\001", ".+")
  tradePattern = s
  return s
end

local function hasTradeLine(bag, slot)
  local pattern = getTradePattern()
  if not pattern or not C_TooltipInfo then return nil end
  local data = C_TooltipInfo.GetBagItem(bag, slot)
  if not data or not data.lines then return nil end
  for _, line in ipairs(data.lines) do
    local text = line.leftText
    if text and text:find(pattern) then return true end
  end
  return false
end

local function markLoot()
  lootUntil = GetTime() + LOOT_WINDOW
end

RB:On("LOOT_OPENED", markLoot)
RB:On("LOOT_READY", markLoot)
RB:On("ENCOUNTER_LOOT_RECEIVED", markLoot)
RB:On("CHALLENGE_MODE_COMPLETED", markLoot)

function RB:CalibBeforeScan(char)
  prevCombined = self:Combine(char)
  prevWatermark = char.watermark
  pending = {}
end

function RB:CalibOnBagItem(loc, bag, slot, cat, ilvl)
  local guid = C_Item.GetItemGUID(loc)
  if not guid or seen[guid] then return end
  seen[guid] = true
  if not ready or GetTime() > lootUntil then return end
  pending[#pending + 1] = { bag = bag, slot = slot, cat = cat, ilvl = ilvl, link = C_Item.GetItemLink(loc) }
end

function RB:CalibAfterScan()
  -- el primer escaneo de la sesión solo memoriza lo que ya había
  if not ready then
    ready = true
    return
  end
  if not pending then return end
  local charKey = self:MyCharKey()
  for _, it in ipairs(pending) do
    local actual = hasTradeLine(it.bag, it.slot)
    if actual ~= nil then
      local ownStrict, ownLoose = self:OwnForCategory(prevCombined, it.cat)
      local rec = {
        ts = self:Now(),
        char = charKey,
        link = it.link,
        cat = it.cat,
        ilvl = it.ilvl,
        ownStrict = ownStrict,
        ownLoose = ownLoose,
        predStrict = it.ilvl <= ownStrict,
        predLoose = it.ilvl <= ownLoose,
        actual = actual,
        wm = prevWatermark,
      }
      local list = self.db.calib
      list[#list + 1] = rec
      while #list > MAX_RECORDS do table.remove(list, 1) end
      if rec.predStrict ~= actual then
        self:Print(("Calibración: %s %s (predicción %s, real %s). Usa /rush debug."):format(
          it.link or "?", it.ilvl, rec.predStrict and "tradeable" or "ligado", actual and "tradeable" or "ligado"))
      end
    end
  end
  pending = nil
end

function RB:CalibReport()
  local list = self.db.calib
  if #list == 0 then
    self:Print("Sin datos de calibración todavía. Se recogen solos al lootear equipo.")
    return
  end
  local okStrict, okLoose = 0, 0
  local misses = {}
  for _, r in ipairs(list) do
    if r.predStrict == r.actual then okStrict = okStrict + 1 else misses[#misses + 1] = r end
    if r.predLoose == r.actual then okLoose = okLoose + 1 end
  end
  self:Print(("Calibración: %d loots. Regla estricta acierta %d, regla laxa %d."):format(#list, okStrict, okLoose))
  for i = math.max(1, #misses - 7), #misses do
    local r = misses[i]
    print(("  %s [%s] ilvl %d · tenías %d/%d · real: %s"):format(
      r.link or "?", RB.SLOT_LABELS[r.cat] or r.cat, r.ilvl, r.ownLoose, r.ownStrict,
      r.actual and "tradeable" or "ligado"))
  end
end
