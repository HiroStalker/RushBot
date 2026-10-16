local _, RB = ...

-- Regla: se puede tradear un objeto del slot X si ya tienes (equipado,
-- bolsas o banco) uno de ese slot con ilvl >= al del objeto.
-- "Tradea todo" = en cada slot, lo mejor que tienes >= ilvl de referencia.
--
-- Anillos y abalorios: por seguridad se exige que los DOS mejores lleguen
-- (regla estricta) hasta que la autocalibración diga lo contrario.
--
-- Armas: según la clase, basta con UNA de sus combinaciones posibles
-- (arma 2M, o arma 1M + escudo/mano izq., o dos armas 1M).

-- Categorías de objeto (Scan.lua) → nombre, para /rush debug.
RB.SLOT_LABELS = {
  HEAD = "Cabeza", NECK = "Cuello", SHOULDER = "Hombros", BACK = "Capa", CHEST = "Pecho",
  WRIST = "Muñecas", HANDS = "Manos", WAIST = "Cintura", LEGS = "Piernas", FEET = "Pies",
  FINGER = "Anillos", TRINKET = "Abalorios", TWOHAND = "Arma 2M", ONEHAND = "Arma 1M",
  MAINHAND = "Mano derecha", OFFWEAPON = "Arma mano izq.", OFFHAND = "Mano izq.", SHIELD = "Escudo",
}

-- Comprobaciones → nombre en la ventana (es) y en el mensaje de Discord (en).
RB.CHECK_ES = {
  HEAD = "Cabeza", NECK = "Cuello", SHOULDER = "Hombros", BACK = "Capa", CHEST = "Pecho",
  WRIST = "Muñecas", HANDS = "Manos", WAIST = "Cintura", LEGS = "Piernas", FEET = "Pies",
  FINGER1 = "Anillo 1", FINGER2 = "Anillo 2", TRINKET1 = "Abalorio 1", TRINKET2 = "Abalorio 2",
  TWOHAND = "Arma 2M", WEAPON1H = "Arma 1M", SHIELD = "Escudo", OFFHAND = "Mano izq.",
  DW_MAIN = "Arma derecha", DW_OFF = "Arma izquierda",
}
RB.CHECK_EN = {
  HEAD = "Head", NECK = "Neck", SHOULDER = "Shoulder", BACK = "Back", CHEST = "Chest",
  WRIST = "Wrist", HANDS = "Hands", WAIST = "Waist", LEGS = "Legs", FEET = "Feet",
  FINGER1 = "Rings", FINGER2 = "Ring", TRINKET1 = "Trinkets", TRINKET2 = "Trinket",
  TWOHAND = "2H Weapon", WEAPON1H = "1H Weapon", SHIELD = "Shield", OFFHAND = "Off-hand",
  DW_MAIN = "Main Hand", DW_OFF = "Off Hand",
}

local SIMPLE = { "HEAD", "NECK", "SHOULDER", "BACK", "CHEST", "WRIST", "HANDS", "WAIST", "LEGS", "FEET" }

-- Combinaciones de armas que puede llevar cada clase.
local WEAPON_SETS = {
  WARRIOR     = { "2H", "1H+SH", "DW" },
  PALADIN     = { "2H", "1H+SH", "1H+OH" },
  DEATHKNIGHT = { "2H", "DW" },
  HUNTER      = { "2H" },
  SHAMAN      = { "2H", "1H+SH", "1H+OH", "DW" },
  EVOKER      = { "2H", "1H+OH" },
  DRUID       = { "2H", "1H+OH" },
  MONK        = { "2H", "1H+OH", "DW" },
  ROGUE       = { "DW" },
  DEMONHUNTER = { "DW" },
  MAGE        = { "2H", "1H+OH" },
  PRIEST      = { "2H", "1H+OH" },
  WARLOCK     = { "2H", "1H+OH" },
}
local ALL_SETS = { "2H", "1H+SH", "1H+OH", "DW" }

-- Mezcla equipado+bolsas con banco, quedándose con los dos mejores por categoría.
function RB:Combine(char)
  local out = {}
  for _, src in ipairs({ char.gear or {}, char.bank or {} }) do
    for cat, t in pairs(src) do
      if t[1] > 0 then RB.AddGear(out, cat, t[1], t[3]) end
      if t[2] > 0 then RB.AddGear(out, cat, t[2], t[4]) end
    end
  end
  return out
end

local function top(c, cat, n)
  local t = c[cat]
  return t and t[n or 1] or 0
end

local function setChecks(c, set)
  local best1H = math.max(top(c, "ONEHAND"), top(c, "MAINHAND"))
  if set == "2H" then
    return { { "TWOHAND", top(c, "TWOHAND") } }
  elseif set == "1H+SH" then
    return { { "WEAPON1H", best1H }, { "SHIELD", top(c, "SHIELD") } }
  elseif set == "1H+OH" then
    return { { "WEAPON1H", best1H }, { "OFFHAND", top(c, "OFFHAND") } }
  elseif set == "DW" then
    local oneA, oneB, mhOnly = top(c, "ONEHAND", 1), top(c, "ONEHAND", 2), top(c, "MAINHAND")
    local mh, oh
    if oneA >= mhOnly then
      mh, oh = oneA, math.max(top(c, "OFFWEAPON"), oneB)
    else
      mh, oh = mhOnly, math.max(top(c, "OFFWEAPON"), oneA)
    end
    return { { "DW_MAIN", mh }, { "DW_OFF", oh } }
  end
  return {}
end

local function minOf(list)
  local m = math.huge
  for _, chk in ipairs(list) do m = math.min(m, chk[2]) end
  return m
end

-- Si alguna combinación de la clase llega al ref, esa; si no, la más cercana.
local function weaponChecks(c, class, ref)
  local best, bestMin
  for _, set in ipairs(WEAPON_SETS[class] or ALL_SETS) do
    local list = setChecks(c, set)
    local m = minOf(list)
    if m >= ref then return list end
    if not bestMin or m > bestMin then best, bestMin = list, m end
  end
  return best or {}
end

-- Lista de { id, ilvl } que se comprueban para el personaje.
function RB:Checks(char, ref)
  ref = ref or self.db.settings.refIlvl or self.DEFAULT_REF_ILVL
  local c = self:Combine(char)
  local list = {}
  for _, cat in ipairs(SIMPLE) do
    list[#list + 1] = { cat, top(c, cat) }
  end
  list[#list + 1] = { "FINGER1", top(c, "FINGER", 1) }
  list[#list + 1] = { "FINGER2", top(c, "FINGER", 2) }
  list[#list + 1] = { "TRINKET1", top(c, "TRINKET", 1) }
  list[#list + 1] = { "TRINKET2", top(c, "TRINKET", 2) }
  for _, w in ipairs(weaponChecks(c, char.class, ref)) do
    list[#list + 1] = w
  end
  return list
end

-- Resultado: { ok, fails = { {id, ilvl} }, noBank }
function RB:Evaluate(char, ref)
  ref = ref or self.db.settings.refIlvl or self.DEFAULT_REF_ILVL
  local fails = {}
  for _, chk in ipairs(self:Checks(char, ref)) do
    if chk[2] < ref then fails[#fails + 1] = chk end
  end
  return {
    ok = #fails == 0,
    fails = fails,
    noBank = not char.bankScanned,
  }
end

-- ilvl propio que se compara con un objeto recién lootado de la categoría cat.
-- strict: para anillos/abalorios usa el segundo mejor; loose: el mejor.
function RB:OwnForCategory(combined, cat)
  if cat == "FINGER" or cat == "TRINKET" or cat == "ONEHAND" then
    return top(combined, cat, 2), top(combined, cat, 1)
  end
  local v = top(combined, cat, 1)
  return v, v
end
