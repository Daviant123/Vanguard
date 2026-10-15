-- Vanguard utilities: lookups, spell/ability checks, JSON encoding, small helpers.

local util = {}

local res = require('resources')

------------------------------------------------------------------------
-- Case-insensitive resource lookups (built once)
------------------------------------------------------------------------
local function build_index(tbl)
    local idx = {}
    for id, entry in pairs(tbl) do
        -- Some names exist twice (poison 3 / 540, Regen 42 / 539): keep the lowest id, the usual one.
        local key = entry.en and entry.en:lower()
        if key and (not idx[key] or (entry.id or id) < (idx[key].id or 0)) then
            idx[key] = entry
        end
    end
    return idx
end

util.spells   = build_index(res.spells)
util.abilities = build_index(res.job_abilities)
util.wskills  = build_index(res.weapon_skills)
util.buffs    = build_index(res.buffs)

function util.spell(name)   return name and util.spells[name:lower()] end
function util.ability(name) return name and util.abilities[name:lower()] end
function util.wskill(name)  return name and util.wskills[name:lower()] end

-- Buff id by name ("Haste", "poison", ...). Returns nil if unknown.
function util.buff_id(name)
    local b = name and util.buffs[name:lower()]
    return b and b.id
end

------------------------------------------------------------------------
-- String helpers
------------------------------------------------------------------------
function util.trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Split "a, b ,c" -> {'a','b','c'} (empty pieces dropped)
function util.split(s, sep)
    local out = {}
    if not s or s == '' then return out end
    sep = sep or ','
    local pattern = '(.-)' .. (sep:gsub('%p', '%%%0'))
    for raw in (s .. sep):gmatch(pattern) do
        local piece = util.trim(raw)
        if piece ~= '' then out[#out + 1] = piece end
    end
    return out
end

------------------------------------------------------------------------
-- Player / mob helpers
------------------------------------------------------------------------
function util.dist(mob)
    if not mob or not mob.distance then return 999 end
    return math.sqrt(mob.distance)
end

function util.has_buff(buff_list, id)
    if not buff_list or not id then return false end
    for _, b in pairs(buff_list) do
        if b == id then return true end
    end
    return false
end

-- Can the player currently use this spell (known, job/level allows it)?
function util.can_cast(spell, player)
    if not spell then return false end
    local known = windower.ffxi.get_spells()
    if not known or not known[spell.id] then return false end
    local lv = spell.levels or {}
    local main_lv = lv[player.main_job_id]
    local sub_lv = lv[player.sub_job_id]
    -- Job Point spells have levels > 99; treat as usable at level 99.
    if main_lv and (main_lv <= player.main_job_level or player.main_job_level >= 99) then return true end
    if sub_lv and sub_lv <= (player.sub_job_level or 0) then return true end
    return false
end

function util.spell_ready(spell, player)
    if not util.can_cast(spell, player) then return false end
    local recasts = windower.ffxi.get_spell_recasts()
    if recasts[spell.recast_id] and recasts[spell.recast_id] > 0 then return false end
    if (spell.mp_cost or 0) > player.vitals.mp then return false end
    return true
end

function util.ability_ready(ja)
    if not ja then return false end
    local recasts = windower.ffxi.get_ability_recasts()
    local r = recasts[ja.recast_id]
    return r == nil or r == 0
end

------------------------------------------------------------------------
-- Minimal JSON encoder (for the desktop bridge)
------------------------------------------------------------------------
local function esc(s)
    return s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        if c == '\n' then return '\\n' end
        return string.format('\\u%04x', c:byte())
    end)
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    return n == #t
end

function util.json(v)
    local tv = type(v)
    if tv == 'nil' then return 'null'
    elseif tv == 'boolean' then return v and 'true' or 'false'
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return '0' end
        return tostring(v)
    elseif tv == 'string' then return '"' .. esc(v) .. '"'
    elseif tv == 'table' then
        local parts = {}
        if next(v) ~= nil and is_array(v) then
            for _, x in ipairs(v) do parts[#parts + 1] = util.json(x) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        for k, x in pairs(v) do
            if type(x) ~= 'function' then
                parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. util.json(x)
            end
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return 'null'
end

------------------------------------------------------------------------
-- Skillchain message ids -> property name, and burst elements
------------------------------------------------------------------------
local sc_names = {'Light','Darkness','Gravitation','Fragmentation','Distortion','Fusion',
    'Compression','Liquefaction','Induration','Reverberation','Transfixion','Scission',
    'Detonation','Impaction'}

util.skillchain_by_msg = {}
for i, name in ipairs(sc_names) do
    util.skillchain_by_msg[287 + i] = name   -- 288..301
    util.skillchain_by_msg[384 + i] = name   -- 385..398 (magic-burst variants)
end
util.skillchain_by_msg[767] = 'Light'     -- Radiance
util.skillchain_by_msg[769] = 'Light'
util.skillchain_by_msg[768] = 'Darkness'  -- Umbra
util.skillchain_by_msg[770] = 'Darkness'

util.burst_elements = {
    Light         = {'Fire', 'Wind', 'Lightning', 'Light'},
    Darkness      = {'Earth', 'Water', 'Ice', 'Dark'},
    Gravitation   = {'Earth', 'Dark'},
    Fragmentation = {'Wind', 'Lightning'},
    Distortion    = {'Water', 'Ice'},
    Fusion        = {'Fire', 'Light'},
    Compression   = {'Dark'},
    Liquefaction  = {'Fire'},
    Induration    = {'Ice'},
    Reverberation = {'Water'},
    Transfixion   = {'Light'},
    Scission      = {'Earth'},
    Detonation    = {'Wind'},
    Impaction     = {'Lightning'},
}

return util
