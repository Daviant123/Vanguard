--[[
Vanguard: Bard songs, after the Singer addon (addons\Singer; user request 2026-10-15: "look at the singer addon to
enhance the BRD profile; it doesn't help to specify what the dummy songs are").

  Song slots    2, or 3 / 4 when an extra-song instrument is in the inventory or a wardrobe (Daurdabla 99: 4;
                Daurdabla 90 / 95, Terpander, Blurred Harp (+1): 3 - Singer's table), +1 under Clarion Call.
                songs.slots = 0 (auto) or 2 / 3 / 4 to set it yourself.
  Dummy songs   songs.dummy = up to three songs (e.g. Army's Paeon, Army's Paeon II, III). With 3+ slots: the first
                two real songs, then one dummy per extra slot (sung with the harp to open the extra slots), then the real 3rd / 4th
                songs over them. Your GearSwap equips the harp for the dummy songs (like with Singer).
  Marcato       songs.marcato_song: Marcato right before that song (default: the first song).
  Clarion Call  songs.clarion_song: the extra song while Clarion Call is up.
  Party range   songs.aoe_names: only sing party songs while these members are within 10' (the song radius).
  Pianissimo    per member, up to two songs each (//vg pianissimo set <name> <1|2> <song|none>).
Only the songs that fit the slots are sung, so they don't overwrite each other.
]]

local util = require('vg_util')

local bard = {}
local S, state, h

local function clock() return os.clock() end

local HARP = { [18571] = 4, [18575] = 3, [18576] = 3, [18839] = 4, [21400] = 3, [21401] = 3, [21407] = 3 }
local HARP_NAME = { [18571] = 'Daurdabla', [18575] = 'Daurdabla', [18576] = 'Daurdabla', [18839] = 'Daurdabla',
                    [21400] = 'Blurred Harp', [21401] = 'Blurred Harp +1', [21407] = 'Terpander' }
local BAGS = { 'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4', 'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8' }

-- Base song slots from the instruments this character owns (checked once a minute).
local cache = { t = -100 }
function bard.instrument()
    if clock() - cache.t < 60 then return cache.slots, cache.name end
    local slots, name = 2, nil
    local all = windower.ffxi.get_items() or {}
    for _, bag in ipairs(BAGS) do
        local items = all[bag]
        if type(items) == 'table' then
            for _, it in ipairs(items) do
                if type(it) == 'table' and HARP[it.id] and HARP[it.id] > slots then slots, name = HARP[it.id], HARP_NAME[it.id] end
            end
        end
    end
    cache.t, cache.slots, cache.name = clock(), slots, name
    return slots, name
end
function bard.forget() cache.t = -100 end

function bard.slots(player)
    local base = tonumber(S.songs.slots) or 0
    if base < 2 then base = bard.instrument() end
    local extra = util.has_buff(player.buffs, 499) and 1 or 0          -- Clarion Call
    return base + extra, base
end

local function list(str) return util.split(str or '', ',') end

-- The songs to keep up now: the list cut to the slots, plus the Clarion Call song.
function bard.wanted(player)
    local slots, base = bard.slots(player)
    local songs = list(S.songs.list)
    local out = {}
    for i = 1, math.min(#songs, base) do out[#out + 1] = songs[i] end
    if slots > base then
        local extra = S.songs.clarion_song ~= '' and S.songs.clarion_song or songs[base + 1]
        if extra then out[#out + 1] = extra end
    end
    return out, slots, base
end

-- Are the members we sing for in range (10')? Empty list = always.
function bard.in_range()
    local names = list(S.songs.aoe_names)
    if #names == 0 then return true end
    local near = {}
    for _, m in ipairs(h.party_members(10.5)) do near[m.name:lower()] = true end
    for _, n in ipairs(names) do
        if not near[n:lower()] then
            -- only wait for members who are actually in the party
            for _, m in ipairs(h.party_members()) do if m.name:lower() == n:lower() then return false, m.name end end
        end
    end
    return true
end

local function active(name)
    local last = state.songs[name:lower()]
    local len = (state.song_len or {})[name:lower()] or S.songs.duration
    return last and clock() - last < len
end

-- One song (or Marcato / a dummy) if something is due. Returns true when it acted.
function bard.sing(player)
    state.song_len = state.song_len or {}
    local wanted, slots, base = bard.wanted(player)
    if #wanted == 0 then return false end
    local due = {}
    for _, name in ipairs(wanted) do
        local last = state.songs[name:lower()]
        local keep = (state.song_len[name:lower()] or S.songs.duration) - S.songs.refresh_before
        if not last or clock() - last > keep then due[#due + 1] = name end
    end
    if #due == 0 then return false end
    local ok, who = bard.in_range()
    if not ok then
        if not h.recently('song_range', 20) then h.mark('song_range') h.log(('Songs: waiting for %s to come within 10\''):format(who)) end
        return false
    end
    if h.nitro(player, true) then return true end
    -- Dummy songs (Singer): with 3+ slots, after the first real songs, fill the extra slots with the dummies.
    local dummies = list(S.songs.dummy)
    if base > 2 and #dummies > 0 then
        local count = 0
        for _, name in ipairs(wanted) do if active(name) then count = count + 1 end end
        for _, name in ipairs(dummies) do if active(name) then count = count + 1 end end
        if count < slots and #wanted > count then
            for i = 1, math.min(#dummies, slots - 2) do
                local d = dummies[i]
                if count == slots - i and not active(d) then
                    if h.try_cast(d, '<me>', 'dummy song (opens a slot)', player) then return true end
                end
            end
        end
    end
    for _, name in ipairs(due) do
        local sp = util.spell(name)
        if sp and util.spell_ready(sp, player) then
            -- Marcato right before its song
            local ms = S.songs.marcato_song ~= '' and S.songs.marcato_song or wanted[1]
            if S.songs.marcato and ms and sp.en:lower() == ms:lower() and not util.has_buff(player.buffs, 231)
                and not util.has_buff(player.buffs, 52) and not h.amnesia(player) and not h.recently('ja:Marcato:<me>', 5) then
                local ja = h.ja_ready('Marcato', player)
                if ja then h.log('Marcato before ' .. sp.en) return h.use_ja(ja, '<me>') end
            end
            if h.try_cast(sp.en, '<me>', 'song', player) then return true end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Pianissimo songs per member: "Song>Name|Name,Song>Name"
------------------------------------------------------------------------
function bard.pian_map()
    local map, order = {}, {}
    for _, entry in ipairs(list(S.songs.pianissimo)) do
        local song, who = entry:match('^(.-)%s*>%s*(.+)$')
        if song then
            for _, n in ipairs(util.split(who, '|')) do
                local key = util.trim(n)
                if not map[key] then map[key] = {} order[#order + 1] = key end
                map[key][#map[key] + 1] = song
            end
        end
    end
    return map, order
end

-- //vg pianissimo set <name> <1|2> <song|none>
function bard.pian_set(name, slot, song)
    slot = tonumber(slot)
    if not name or not slot or slot < 1 or slot > 2 then return false end
    local sp = song and song ~= 'none' and song ~= '' and util.spell(song)
    if song and song ~= 'none' and song ~= '' and (not sp or sp.type ~= 'BardSong') then return false end
    local map, order = bard.pian_map()
    local key
    for _, n in ipairs(order) do if n:lower() == name:lower() then key = n end end
    if not key then key = name order[#order + 1] = key map[key] = {} end
    local songs = map[key]
    songs[slot] = sp and sp.en or nil
    local clean = {}
    for i = 1, 2 do if songs[i] then clean[#clean + 1] = songs[i] end end
    map[key] = clean
    local entries = {}
    for _, n in ipairs(order) do
        for _, s in ipairs(map[n] or {}) do entries[#entries + 1] = s .. '>' .. n end
    end
    S.songs.pianissimo = table.concat(entries, ',')
    return true
end

-- People the panel can add to the Pianissimo table: alliance members, other Vanguard characters, players nearby.
function bard.candidates(player)
    local seen, out = { [player.name:lower()] = true }, {}
    local function add(n) if n and n ~= '' and not seen[n:lower()] then seen[n:lower()] = true out[#out + 1] = n end end
    local pt = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p1', 'p2', 'p3', 'p4', 'p5', 'a10', 'a11', 'a12', 'a13', 'a14', 'a15', 'a20', 'a21', 'a22', 'a23', 'a24', 'a25' }) do
        add(pt[k] and pt[k].name)
    end
    for name in pairs(require('vg_party').known or {}) do add(name) end
    local me = windower.ffxi.get_mob_by_target('me')
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if type(m) == 'table' and not m.is_npc and m.spawn_type == 13 and m.name and util.dist(m) <= 30 then add(m.name) end
    end
    table.sort(out)
    return out
end

-- What the panel shows.
function bard.info(player)
    local slots, base = bard.slots(player)
    local _, harp = bard.instrument()
    local map = bard.pian_map()
    return { slots = slots, base = base, instrument = harp or 'none', auto = (tonumber(S.songs.slots) or 0) < 2,
             pianissimo = map, candidates = bard.candidates(player) }
end

function bard.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return bard
