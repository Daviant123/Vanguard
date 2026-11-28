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

local target_bits = { Self = 1, Player = 2, Party = 4, Ally = 8, NPC = 16, Enemy = 32, Corpse = 64 }
-- Does a spell / ability target <what> (Self, Party, Enemy...)? Windower gives targets as a set of names; the raw
-- resource files have a number.
function util.targets(entry, what)
    local t = entry and entry.targets
    if type(t) == 'number' then return math.floor(t / target_bits[what]) % 2 == 1 end
    if type(t) == 'table' then
        if t[what] then return true end
        for _, v in pairs(t) do if v == what then return true end end
    end
    return false
end

-- Is this entity a player character? spawn_type 1 = another player, 13 = in my party, 9 = in my alliance (14 = a
-- trust, 16 = a monster, 2 / 34 = an NPC), as the InfoBar addon reads them. (Vanguard used 13 alone, which misses every
-- player outside the party.)
function util.is_player(m)
    return type(m) == 'table' and not m.is_npc and (m.spawn_type == 1 or m.spawn_type == 9 or m.spawn_type == 13)
end

-- Per-job saved setups (profiles, menus) are kept under the job in lower case: Windower's config library lower-cases
-- every tag name when it reads settings.xml, so "PLD" saved came back as "pld" and every reload / update started the
-- job from its defaults (farming off, his job setup gone - found in his real game 2026-10-17). Old "PLD" keys are
-- still read.
function util.job_get(t, job)
    if type(t) ~= 'table' or not job then return nil end
    local v = rawget(t, job:lower())
    if v == nil or v == '' then v = rawget(t, job) end
    return v
end

function util.job_set(t, job, v)
    if type(t) ~= 'table' or not job then return end
    rawset(t, job:lower(), v)
    if job ~= job:lower() then rawset(t, job, nil) end
end

function util.spell(name)   return name and util.spells[name:lower()] end
function util.ability(name) return name and util.abilities[name:lower()] end
function util.wskill(name)  return name and util.wskills[name:lower()] end
-- Can the weapon in the main hand use it? The game's own list changes with the weapon (his log 2026-10-30: DRK with a scythe, and
-- Expiacion and Atonement from his BLU's settings sent over and over). An empty list says nothing (just zoned, Amnesia).
-- "X doesn't work with the weapon in your hand" is said once per weapon, not every minute (his question 2026-11-11: "why do i
-- keep getting [it] for weaponskills that are not being used" - CharC's Keep Aftermath / Finish with were set for
-- another weapon). true = say it now. Said again after a weapon it fits (util.ws_fits clears it) or another weapon.
local unfit_said = {}
function util.ws_unfit_note(name, where)
    local ab = windower.ffxi.get_abilities()
    local sum, n = 0, 0
    for _, id in pairs(ab and ab.weapon_skills or {}) do sum, n = sum + id, n + 1 end
    local k = tostring(name):lower()
    unfit_said[k] = unfit_said[k] or {}
    local sig = n .. ':' .. sum
    if unfit_said[k][where or ''] == sig then return false end
    unfit_said[k][where or ''] = sig
    return true
end

function util.ws_fits(name)
    local w = util.wskill(name)
    local ab = windower.ffxi.get_abilities()
    local ids = ab and ab.weapon_skills
    if not w or not ids or next(ids) == nil then return true end
    for _, id in pairs(ids) do if id == w.id then unfit_said[w.en:lower()] = nil return true end end
    return false
end

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
-- Everyone in my party AND the other two parties of an alliance (a1x / a2x), by mob id. In FFXI any alliance member
-- may attack a monster another alliance member claimed (his report 2026-11-21: in an alliance, CharA engaged mobs
-- claimed by the other parties, Vanguard took them for "someone else's" and sent /attackoff, over and over).
util.ALLIANCE_KEYS = { 'p0', 'p1', 'p2', 'p3', 'p4', 'p5', 'a10', 'a11', 'a12', 'a13', 'a14', 'a15',
                       'a20', 'a21', 'a22', 'a23', 'a24', 'a25' }
function util.alliance_ids(ids)
    ids = ids or {}
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs(util.ALLIANCE_KEYS) do
        local m = p[k]
        local mob = m and (m.mob or (m.name and windower.ffxi.get_mob_by_name(m.name)))
        if mob and mob.id then ids[mob.id] = true end
    end
    return ids
end

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

-- Unable to act at all (CurePlease audit 1.1): nothing - spell, ability, weapon skill or item - can be used, so
-- nothing is sent (the game would refuse it and the anti-spam waits would delay the right action once it wears off).
-- Buff ids checked against res/buffs.lua: 2 / 19 sleep, 7 petrification, 10 stun, 14 / 17 charm, 28 terror.
-- (Silence 6 / mute 29 only stop spells: that's the 'silenced' check in Vanguard.lua.) Returns the state's name.
util.INCAPACITATED = { [2] = 'asleep', [19] = 'asleep', [7] = 'petrified', [10] = 'stunned', [14] = 'charmed',
                       [17] = 'charmed', [28] = 'terrorized' }
function util.incapacitated(buff_list)
    if not buff_list then return nil end
    for _, b in pairs(buff_list) do
        if util.INCAPACITATED[b] then return util.INCAPACITATED[b] end
    end
    return nil
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
-- Blue magic is castable only while it's set (learned isn't enough): the set spells of the BLU main / sub job
local blu_set = { t = -100, ids = {} }
function util.blu_set()
    if os.clock() - blu_set.t < 5 then return blu_set.ids end
    blu_set.t, blu_set.ids = os.clock(), {}
    for _, f in ipairs({ 'get_mjob_data', 'get_sjob_data' }) do
        local ok, d = pcall(function() return windower.ffxi[f] and windower.ffxi[f]() end)
        if ok and type(d) == 'table' and type(d.spells) == 'table' then
            for _, id in pairs(d.spells) do if tonumber(id) and id ~= 512 then blu_set.ids[id] = true end end
        end
    end
    return blu_set.ids
end

-- Unbridled spells (Mighty Guard, Carcharian Verve...): never set; a main-job BLU casts them only while Unbridled
-- Learning or Unbridled Wisdom is up (his request 2026-11-09: "there is no way to use the spells under unbridled learning")
util.UNBRIDLED_NAMES = { 'Thunderbolt', 'Harden Shell', 'Absolute Terror', 'Gates of Hades', 'Tourbillion',
    'Pyric Bulwark', 'Bilgestorm', 'Bloodrake', 'Droning Whirlwind', 'Carcharian Verve', 'Blistering Roar', 'Uproot',
    'Crashing Thunder', 'Polar Roar', 'Mighty Guard', 'Cruel Joke', 'Cesspool', 'Tearing Gust' }
local unbridled_set
function util.unbridled(spell)
    if not spell or spell.type ~= 'BlueMagic' then return false end
    if not unbridled_set then
        unbridled_set = {}
        for _, n in ipairs(util.UNBRIDLED_NAMES) do unbridled_set[n:lower()] = true end
    end
    return unbridled_set[(spell.en or ''):lower()] == true
end
util.UNBRIDLED_BUFFS = { 485, 505 }            -- Unbridled Learning, Unbridled Wisdom
function util.unbridled_up(buffs)
    return util.has_buff(buffs, 485) or util.has_buff(buffs, 505)
end

-- opts.unbridled: count an Unbridled spell as castable without the buff (the action engine uses Unbridled Learning first)
-- Scholar spells that need Addendum: White (401) / Addendum: Black (402) up
util.ADDENDUM = {}
for _, n in ipairs({ 'Poisona', 'Paralyna', 'Blindna', 'Silena', 'Stona', 'Viruna', 'Cursna', 'Erase', 'Raise II',
    'Raise III', 'Reraise', 'Reraise II', 'Reraise III' }) do util.ADDENDUM[n] = 401 end
for _, n in ipairs({ 'Sleep', 'Sleep II', 'Dispel', 'Break', 'Stone IV', 'Water IV', 'Aero IV', 'Fire IV', 'Blizzard IV',
    'Thunder IV', 'Stone V', 'Water V', 'Aero V', 'Fire V', 'Blizzard V', 'Thunder V' }) do util.ADDENDUM[n] = 402 end

function util.can_cast(spell, player, opts)
    if not spell then return false end
    local known = windower.ffxi.get_spells()
    if not known or (not known[spell.id] and not util.instrument_song(spell)) then return false end
    if util.unbridled(spell) then
        if player.main_job ~= 'BLU' then return false end              -- Unbridled Learning is main-job BLU only
        if not (util.unbridled_up(player.buffs) or (opts and opts.unbridled)) then return false end
    -- unset blue magic: the game refuses it (pull with a blue spell, quick buttons...; 2026-10-19)
    elseif spell.type == 'BlueMagic' and (player.main_job == 'BLU' or player.sub_job == 'BLU')
        and (windower.ffxi.get_mjob_data or windower.ffxi.get_sjob_data) and not util.blu_set()[spell.id] then return false end
    local lv = spell.levels or {}
    local main_lv = lv[player.main_job_id]
    local sub_lv = lv[player.sub_job_id]
    -- a Scholar's Addendum spell only casts under its Addendum (his RDM/SCH CharB, 2026-11-12: Reraise sent every 11 s
    -- for 15 minutes without Addendum: White, each one refused)
    local function sch_ok(job)
        if job ~= 'SCH' or (opts and opts.addendum) then return true end   -- (opts.addendum: lists to pick from)
        local need = util.ADDENDUM[spell.en]
        return not need or util.has_buff(player.buffs, need)
    end
    -- Job Point spells have levels > 99; treat as usable at level 99.
    if main_lv and (main_lv <= player.main_job_level or player.main_job_level >= 99) and sch_ok(player.main_job) then return true end
    if sub_lv and sub_lv <= (player.sub_job_level or 0) and sch_ok(player.sub_job) then return true end
    return false
end

function util.spell_ready(spell, player, opts)
    if not util.can_cast(spell, player, opts) then return false end
    local recasts = windower.ffxi.get_spell_recasts()
    if recasts[spell.recast_id] and recasts[spell.recast_id] > 0 then return false end
    if (spell.mp_cost or 0) > player.vitals.mp then return false end
    return true
end

-- Only an ability this character has on its current jobs: one from another job has no recast timer at all, which read
-- as "ready" (his report 2026-11-11: CharB on WHM/SCH kept trying Convert, a Red Mage ability, at low MP).
-- An empty ability list says nothing (just zoned).
function util.ability_known(ja)
    local ab = windower.ffxi.get_abilities()
    local ids = ab and ab.job_abilities
    if not ja or not ids or next(ids) == nil then return true end
    for _, id in pairs(ids) do if id == ja.id then return true end end
    return false
end

function util.ability_ready(ja)
    if not ja or not util.ability_known(ja) then return false end
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

------------------------------------------------------------------------
-- Monster TP moves that buff the monster (1.2.0, Silmaril audit 2.4): move name -> the buff it gives, and whether
-- Dispel can take it off. Looked up by NAME in res.monster_abilities (the same move has several ids, one per mob
-- family), never by a fixed number. Invincible and Perfect Dodge (the mob's two-hour abilities) can't be dispelled
-- (bg-wiki), so a dispeller doesn't waste MP on them; for anything not known here we keep dispelling as before.
------------------------------------------------------------------------
util.MOB_BUFF_MOVES = {
    ['Invincible']       = { buff = 'Invincible',    dispel = false },
    ['Perfect Dodge']    = { buff = 'Perfect Dodge', dispel = false },
    ['Granite Skin']     = { buff = 'Stoneskin',     dispel = true },
    ['Metallic Body']    = { buff = 'Stoneskin',     dispel = true },
    ['Mighty Guard']     = { buff = 'Mighty Guard',  dispel = true },
    ['Dark Thorn']       = { buff = 'Dread Spikes',  dispel = true },
    ['Animating Wail']   = { buff = 'Haste',         dispel = true },
    ['Fortifying Wail']  = { buff = 'Protect',       dispel = true },
    ['Rhino Guard']      = { buff = 'Evasion Boost', dispel = true },
    ['Scissor Guard']    = { buff = 'Defense Boost', dispel = true },
    ['Infernal Bulwark'] = { buff = 'Infernal Bulwark', dispel = true },   -- (several defence buffs; name kept)
}
-- buffs Dispel can't remove, by name (a "gains the effect of X" message names the buff itself)
util.UNDISPELLABLE = { ['invincible'] = true, ['perfect dodge'] = true }

local mob_move_ids
-- The buff a monster TP move (res.monster_abilities id) gives: { move = name, buff = name, dispel = bool } or nil.
function util.mob_move_buff(ability_id)
    if not mob_move_ids then
        mob_move_ids = {}
        for id, ab in pairs(res.monster_abilities or {}) do
            local e = ab.en and util.MOB_BUFF_MOVES[ab.en]
            if e then mob_move_ids[ab.id or id] = { move = ab.en, buff = e.buff, dispel = e.dispel } end
        end
    end
    return ability_id and mob_move_ids[ability_id]
end

-- Can Dispel take this buff (a name) off a mob? Unknown buffs: yes (keep dispelling when unsure).
function util.dispellable(buff_name)
    return not (buff_name and util.UNDISPELLABLE[buff_name:lower()])
end

return util
