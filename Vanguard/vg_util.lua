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

-- Songs that come with an instrument instead of a scroll (they aren't in the learned-spell list): available
-- while that instrument is in the inventory or a wardrobe (Singer does the same for Marsyas).
util.INSTRUMENT_SONGS = { ['honor march'] = { 21398 },                          -- Marsyas
                          ['aria of passion'] = { 22304, 22305, 22306, 22307 } }  -- Loughnashade
local owned = { t = -100, ids = {} }
local BAGS = { 'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4', 'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8' }
function util.owns(ids)
    if os.clock() - owned.t > 60 then
        owned.t, owned.ids = os.clock(), {}
        local all = windower.ffxi.get_items() or {}
        for _, bag in ipairs(BAGS) do
            if type(all[bag]) == 'table' then
                for _, it in ipairs(all[bag]) do if type(it) == 'table' and it.id then owned.ids[it.id] = true end end
            end
        end
    end
    for _, id in ipairs(ids) do if owned.ids[id] then return true end end
    return false
end
function util.forget_items() owned.t = -100 end
function util.instrument_song(spell)
    local ids = spell and spell.en and util.INSTRUMENT_SONGS[spell.en:lower()]
    return ids ~= nil and util.owns(ids)
end

-- Can the player currently use this spell (known, job/level allows it)?
function util.can_cast(spell, player)
    if not spell then return false end
    local known = windower.ffxi.get_spells()
    if not known or (not known[spell.id] and not util.instrument_song(spell)) then return false end
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

-- Minimal JSON decoder (profiles sent by Vanguard Control). Returns value or nil, error.
function util.json_decode(str)
    local pos = 1
    local function ws() pos = str:find('[^ \t\r\n]', pos) or (#str + 1) end
    local value
    local function err(msg) error(('JSON %s at %d'):format(msg, pos), 0) end
    local function str_val()
        local out, i = {}, pos + 1
        while true do
            local c = str:sub(i, i)
            if c == '' then err('unterminated string') end
            if c == '"' then pos = i + 1 return table.concat(out) end
            if c == '\\' then
                local n = str:sub(i + 1, i + 1)
                local map = { ['"'] = '"', ['\\'] = '\\',['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if map[n] then out[#out + 1] = map[n] i = i + 2
                elseif n == 'u' then
                    local code = tonumber(str:sub(i + 2, i + 5), 16) or 63
                    out[#out + 1] = code < 128 and string.char(code) or '?'
                    i = i + 6
                else err('bad escape') end
            else out[#out + 1] = c i = i + 1 end
        end
    end
    value = function()
        ws()
        local c = str:sub(pos, pos)
        if c == '{' then
            local t = {}
            pos = pos + 1 ws()
            if str:sub(pos, pos) == '}' then pos = pos + 1 return t end
            while true do
                ws()
                if str:sub(pos, pos) ~= '"' then err('expected key') end
                local k = str_val() ws()
                if str:sub(pos, pos) ~= ':' then err('expected :') end
                pos = pos + 1
                t[k] = value() ws()
                local d = str:sub(pos, pos) pos = pos + 1
                if d == '}' then return t end
                if d ~= ',' then err('expected , or }') end
            end
        elseif c == '[' then
            local t = {}
            pos = pos + 1 ws()
            if str:sub(pos, pos) == ']' then pos = pos + 1 return t end
            while true do
                t[#t + 1] = value() ws()
                local d = str:sub(pos, pos) pos = pos + 1
                if d == ']' then return t end
                if d ~= ',' then err('expected , or ]') end
            end
        elseif c == '"' then return str_val()
        elseif str:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
        elseif str:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
        elseif str:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
        else
            local num = str:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
            if not num or num == '' then err('unexpected character') end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local ok, res = pcall(value)
    if not ok then return nil, res end
    return res
end

------------------------------------------------------------------------
-- Buffs for the app's Party board: name + whether it's an ailment (red, clickable to cure)
------------------------------------------------------------------------
local BAD = {}
for _, n in ipairs({ 'poison', 'paralysis', 'blindness', 'silence', 'petrification', 'disease', 'plague', 'curse',
    'doom', 'sleep', 'stun', 'terror', 'charm', 'amnesia', 'weight', 'bind', 'slow', 'addle', 'weakness', 'impairment',
    'encumbrance', 'mute', 'elegy', 'requiem', 'threnody', 'helix', 'bio', 'dia', 'flash', 'burn', 'frost', 'choke',
    'rasp', 'shock', 'drown', 'max hp down', 'max mp down', 'attack down', 'defense down', 'accuracy down',
    'evasion down', 'magic atk. down', 'magic acc. down', 'magic def. down', 'str down', 'dex down', 'vit down',
    'agi down', 'int down', 'mnd down', 'chr down', 'lullaby', 'gravity' }) do BAD[n] = true end
util.AILMENT = BAD

function util.buff_list(ids)
    local out, seen = {}, {}
    for _, id in pairs(ids or {}) do
        local b = res.buffs[id]
        local name = b and b.en
        if name and not seen[name:lower()] then
            seen[name:lower()] = true
            out[#out + 1] = { n = name, b = BAD[name:lower()] or nil }
        end
    end
    table.sort(out, function(x, y) if (x.b or false) ~= (y.b or false) then return x.b == true end return x.n < y.n end)
    return out
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
