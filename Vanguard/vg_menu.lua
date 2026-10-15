--[[
Vanguard menu: what the control panel shows as checkboxes and dropdowns.

- catalog(): the spells this character can cast right now, sorted into
  party buffs, self buffs, enfeebles, songs, Indi/Geo bubbles and cleanses.
- encode()/apply(): per-job saved choices (buff grid, songs, geo, enfeebles, modules).
- command(): "//vg menu ..." changes coming from the panel.
]]

local util = require('vg_util')
local res = require('resources')

local menu = {}

------------------------------------------------------------------------
-- Spell catalog
------------------------------------------------------------------------
local target_bits = { Self = 1, Player = 2, Party = 4, Ally = 8, NPC = 16, Enemy = 32, Corpse = 64 }

local function targets(spell, what)
    local t = spell.targets
    if type(t) == 'number' then return math.floor(t / target_bits[what]) % 2 == 1 end
    if type(t) == 'table' then
        if t[what] then return true end
        for _, v in pairs(t) do if v == what then return true end end
    end
    return false
end

local roman = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6 }

-- "Protect V" -> "Protect", 5 ; "Haste" -> "Haste", 1
local function family(name)
    local base, num = name:match('^(.-)%s+([IVX]+)$')
    if base and roman[num] then return base, roman[num] end
    return name, 1
end

local function castable(spell, player, known)
    if not known[spell.id] then return false end
    local lv = spell.levels or {}
    local m, s = lv[player.main_job_id], lv[player.sub_job_id]
    if m and (m <= player.main_job_level or player.main_job_level >= 99) then return true end
    if s and s <= (player.sub_job_level or 0) then return true end
    return false
end

-- Display order for the party buff grid (anything else follows alphabetically).
local buff_order = {
    'Haste', 'Refresh', 'Regen', 'Protect', 'Shell', 'Phalanx', 'Flurry', 'Adloquium',
    'Protectra', 'Shellra', 'Firestorm', 'Hailstorm', 'Windstorm', 'Sandstorm',
    'Thunderstorm', 'Rainstorm', 'Aurorastorm', 'Voidstorm', 'Embrava',
}
local order_rank = {}
for i, n in ipairs(buff_order) do order_rank[n:lower()] = i end

local function sort_buffs(list)
    table.sort(list, function(a, b)
        local fa, fb = family(a):lower(), family(b):lower()
        local ra, rb = order_rank[fa] or 999, order_rank[fb] or 999
        if ra ~= rb then return ra < rb end
        return a < b
    end)
end

-- Keep only the highest tier of each family ("Protect V", not I-IV).
local function best_tiers(names)
    local best = {}
    for _, n in ipairs(names) do
        local fam, tier = family(n)
        local cur = best[fam]
        if not cur or tier > cur.tier then best[fam] = { name = n, tier = tier } end
    end
    local out = {}
    for _, v in pairs(best) do out[#out + 1] = v.name end
    return out
end

local never_debuff = { sleep = true, sleepga = true, lullaby = true, repose = true, ['foe lullaby'] = true,
                       ['horde lullaby'] = true }

local cache = { key = nil, time = 0, data = nil }

-- status_cures: {{status name, spell name}, ...} from the healer code.
function menu.catalog(player, status_cures)
    local key = ('%s%d/%s%d'):format(player.main_job or '', player.main_job_level or 0,
        player.sub_job or '', player.sub_job_level or 0)
    if cache.key == key and os.clock() - cache.time < 120 then return cache.data end

    local known = windower.ffxi.get_spells() or {}
    local party, self_only, debuffs, songs, indi, geo = {}, {}, {}, {}, {}, {}
    local has = {}
    for id, spell in pairs(res.spells) do
        if spell.en and castable(spell, player, known) then
            local name, t = spell.en, spell.type
            has[name:lower()] = true
            if t == 'BardSong' then
                if targets(spell, 'Enemy') then
                    if spell.status and not never_debuff[name:lower()] then debuffs[#debuffs + 1] = name end
                else
                    songs[#songs + 1] = name
                end
            elseif t == 'Geomancy' then
                if name:sub(1, 5) == 'Indi-' then indi[#indi + 1] = name
                elseif name:sub(1, 4) == 'Geo-' then geo[#geo + 1] = name end
            elseif spell.status and (t == 'WhiteMagic' or t == 'BlackMagic' or t == 'Ninjutsu') then
                if targets(spell, 'Enemy') then
                    local fam = family(name):lower()
                    if not never_debuff[fam] then debuffs[#debuffs + 1] = name end
                elseif t ~= 'Ninjutsu' and (targets(spell, 'Party') or targets(spell, 'Ally')) then
                    party[#party + 1] = name
                elseif targets(spell, 'Self') then
                    self_only[#self_only + 1] = name
                end
            end
        end
    end

    party, self_only = best_tiers(party), best_tiers(self_only)
    sort_buffs(party)
    table.sort(self_only)
    debuffs = best_tiers(debuffs)
    table.sort(debuffs)
    table.sort(songs)
    table.sort(indi)
    table.sort(geo)

    local cleanse, seen = {}, {}
    for _, pair in ipairs(status_cures) do
        if has[pair[2]:lower()] and not seen[pair[1]] then
            seen[pair[1]] = true
            cleanse[#cleanse + 1] = pair[1]
        end
    end

    local function any(...)
        for _, n in ipairs({...}) do if has[n:lower()] then return true end end
        return false
    end

    cache.data = {
        party_buffs = party, self_buffs = self_only, debuffs = debuffs,
        songs = songs, indi = indi, geo = geo, cleanse = cleanse,
        can_cure = any('Cure', 'Cure II', 'Cure III', 'Cure IV', 'Cure V', 'Cure VI'),
        can_curaga = any('Curaga', 'Curaga II', 'Curaga III', 'Curaga IV', 'Curaga V'),
        can_raise = any('Raise', 'Raise II', 'Raise III', 'Arise'),
        can_dispel = any('Dispel', 'Dispelga'),
    }
    cache.key, cache.time = key, os.clock()
    return cache.data
end

function menu.reset_cache() cache.key = nil end

-- Party member names, self first.
function menu.party()
    local out = {}
    local p = windower.ffxi.get_party()
    if not p then return out end
    for _, k in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
        if p[k] and p[k].name then out[#out + 1] = p[k].name end
    end
    return out
end

------------------------------------------------------------------------
-- What's currently chosen (sent to the panel)
------------------------------------------------------------------------
function menu.config(settings)
    return {
        buffs = util.split(settings.buffs.list, ','),
        songs = util.split(settings.songs.list, ','),
        debuffs = util.split(settings.debuff.list, ','),
        indi = settings.geo.indi, geo = settings.geo.geo, geo_target = settings.geo.geo_target,
        entrust = settings.geo.entrust,
        heal = {
            cure_at = settings.heal.cure_at, curaga_at = settings.heal.curaga_at,
            curaga_count = settings.heal.curaga_count, priority_at = settings.heal.priority_at,
            priority = util.split(settings.heal.priority, ','), ignore = util.split(settings.heal.ignore, ','),
            wake_sleep = settings.heal.wake_sleep, curaga = settings.heal.curaga,
        },
        cleanse_skip = util.split(settings.cleanse.skip, ','),
        songs_when = settings.songs.when,
        debuff_retries = settings.debuff.retries,
        modules = settings.modules,
    }
end

------------------------------------------------------------------------
-- Per-job save format: b=..|s=..|i=..|g=..|gt=..|e=..|d=..|m=a+b
-- (';' separates list items; commas would be split by Windower's config library)
------------------------------------------------------------------------
local function semi(s) return table.concat(util.split(s, ','), ';') end
local function comma(s) return table.concat(util.split(s or '', ';'), ',') end

function menu.encode(settings)
    local on = {}
    for k, v in pairs(settings.modules) do if v then on[#on + 1] = k end end
    table.sort(on)
    return ('b=%s|s=%s|i=%s|g=%s|gt=%s|e=%s|d=%s|m=%s'):format(
        semi(settings.buffs.list), semi(settings.songs.list), settings.geo.indi, settings.geo.geo,
        settings.geo.geo_target, settings.geo.entrust, semi(settings.debuff.list), table.concat(on, '+'))
end

function menu.apply(settings, str)
    local f = {}
    for k, v in str:gmatch('(%w+)=([^|]*)') do f[k] = v end
    settings.buffs.list = comma(f.b)
    settings.songs.list = comma(f.s)
    settings.geo.indi, settings.geo.geo = f.i or '', f.g or ''
    settings.geo.geo_target = (f.gt and f.gt ~= '') and f.gt or 'bt'
    settings.geo.entrust = f.e or ''
    settings.debuff.list = comma(f.d)
    if f.m then
        local on = {}
        for _, k in ipairs(util.split(f.m, '+')) do on[k] = true end
        for k in pairs(settings.modules) do settings.modules[k] = on[k] == true end
    end
end

------------------------------------------------------------------------
-- Commands from the panel
------------------------------------------------------------------------
local function same(a, b) return a:lower() == b:lower() end

-- Add or remove a name from a comma list setting.
local function toggle_in(list_str, item, on)
    local out = {}
    for _, x in ipairs(util.split(list_str, ',')) do
        if not same(x, item) then out[#out + 1] = x end
    end
    if on then out[#out + 1] = item end
    return table.concat(out, ',')
end

local function rest_of(args, from)
    local parts = {}
    for i = from, #args do parts[#parts + 1] = args[i] end
    return util.trim(table.concat(parts, ' '))
end

local function is_on(v) v = (v or ''):lower() return v == 'on' or v == 'true' or v == '1' end

-- Returns a short log message, or nil if the command was not understood.
function menu.command(settings, args, player)
    local sub = (args[1] or ''):lower()
    local me = player and player.name or ''

    if sub == 'buff' then
        -- menu buff <who|me> on|off <spell>
        local who, on, spell = args[2] or 'me', is_on(args[3]), rest_of(args, 4)
        if spell == '' then return nil end
        if same(who, me) then who = 'me' end
        local out = {}
        for _, entry in ipairs(util.split(settings.buffs.list, ',')) do
            local what, tgt = entry:match('^(.-)%s*>%s*(.+)$')
            what, tgt = what or entry, tgt or 'me'
            if same(tgt, me) then tgt = 'me' end
            if not (same(what, spell) and same(tgt, who)) then out[#out + 1] = entry end
        end
        if on then out[#out + 1] = spell .. '>' .. who end
        settings.buffs.list = table.concat(out, ',')
        if on then settings.modules.buffs = true end
        return ('%s on %s: %s'):format(spell, who, on and 'on' or 'off')

    elseif sub == 'song' then
        -- menu song <slot> <song|none>
        local slot, name = tonumber(args[2]), rest_of(args, 3)
        if not slot then return nil end
        local songs = util.split(settings.songs.list, ',')
        local fixed = {}
        for i = 1, math.max(#songs, slot) do fixed[i] = songs[i] or '' end
        fixed[slot] = (name:lower() == 'none') and '' or name
        local out = {}
        for i = 1, #fixed do if fixed[i] ~= '' then out[#out + 1] = fixed[i] end end
        settings.songs.list = table.concat(out, ',')
        settings.modules.songs = #out > 0
        return 'Songs: ' .. (#out > 0 and table.concat(out, ', ') or 'none')

    elseif sub == 'debuff' then
        local on, spell = is_on(args[2]), rest_of(args, 3)
        if spell == '' then return nil end
        settings.debuff.list = toggle_in(settings.debuff.list, spell, on)
        if on then settings.modules.debuff = true end
        return spell .. ': ' .. (on and 'on' or 'off')

    elseif sub == 'indi' or sub == 'geo' then
        local name = rest_of(args, 2)
        if name:lower() == 'none' then name = '' end
        settings.geo[sub] = name
        settings.modules.geo = settings.geo.indi ~= '' or settings.geo.geo ~= ''
        return sub .. ': ' .. (name ~= '' and name or 'none')

    elseif sub == 'geotarget' then
        settings.geo.geo_target = args[2] or 'bt'
        return 'Geo target: ' .. settings.geo.geo_target

    elseif sub == 'entrust' then
        -- menu entrust <member|none> <Indi-spell>
        local who, spell = args[2] or 'none', rest_of(args, 3)
        if who:lower() == 'none' or spell == '' or spell:lower() == 'none' then
            settings.geo.entrust = ''
            return 'Entrust: off'
        end
        settings.geo.entrust = spell .. '>' .. who
        return ('Entrust: %s on %s'):format(spell, who)

    elseif sub == 'heal' then
        -- menu heal <member> on|off   (off = don't cure or cleanse them)
        local who, on = args[2], is_on(args[3])
        if not who then return nil end
        settings.heal.ignore = toggle_in(settings.heal.ignore, who, not on)
        return ('Heal %s: %s'):format(who, on and 'on' or 'off')

    elseif sub == 'priority' then
        local who, on = args[2], is_on(args[3])
        if not who then return nil end
        settings.heal.priority = toggle_in(settings.heal.priority, who, on)
        return ('Priority %s: %s'):format(who, on and 'on' or 'off')

    elseif sub == 'cleanse' then
        -- menu cleanse on|off <status>
        local on, status = is_on(args[2]), rest_of(args, 3)
        if status == '' then return nil end
        settings.cleanse.skip = toggle_in(settings.cleanse.skip, status, not on)
        return ('Remove %s: %s'):format(status, on and 'on' or 'off')
    end
    return nil
end

return menu
