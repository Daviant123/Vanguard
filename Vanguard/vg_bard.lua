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
    -- an instrument gives at most 4; the 5th only while Clarion Call is up. "5 songs" picked by hand without it had the
    -- bard singing a 5th song that knocked another off, round and round (2026-10-18)
    base = math.min(base, 4)
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

------------------------------------------------------------------------
-- The bard's own songs on itself, kept like Ivaar's Singer does (2026-10-18 rework, his request "the songs need to be
-- fixed ... so that it works well"): a song that lands is added; with every slot full it replaces the one with the
-- least time left (the game's rule - bg-wiki's bard guides), the same song sung again replaces itself; the game's
-- "wears off" messages and its buff timers take songs away and correct their times. Another bard's songs on us don't
-- count (each bard has its own slots). state.mysongs[name] = { name, status, at, ends, troub, sv } (os.clock times).
------------------------------------------------------------------------
local function mine()
    state.mysongs = state.mysongs or {}
    local t = clock()
    for k, x in pairs(state.mysongs) do if x.ends <= t then state.mysongs[k] = nil end end
    return state.mysongs
end
local function count(m) local n = 0 for _ in pairs(m) do n = n + 1 end return n end
-- the song with the least time left (of one buff, if given)
local function shortest(m, status)
    local best, key
    for k, x in pairs(m) do
        if (not status or x.status == status) and (not best or x.ends < best) then best, key = x.ends, k end
    end
    return key
end
local function on(name) return mine()[name:lower()] end

-- how long a song sung now lasts: learned from the game's timer for that song, else the "Songs last" setting
local function length(key, troub)
    local base = (state.song_base or {})[key] or tonumber(S.songs.duration) or 240
    return base * (troub and 2 or 1)
end

-- one of our songs landed on us (the 'action' event, Vanguard.lua)
function bard.on_song(spell, player)
    local m = mine()
    local key = spell.en:lower()
    local troub = util.has_buff(player.buffs, 348)
    if not m[key] and count(m) >= (bard.slots(player)) then
        -- a dummy goes first: they're the short ones (sung without duration gear); the game's timers correct it if not
        local dummy = {}
        for _, d in ipairs(list(S.songs.dummy)) do dummy[d:lower()] = true end
        for _, w in ipairs(list(S.songs.list)) do dummy[w:lower()] = nil end
        local gone, best
        for k, x in pairs(m) do
            local rank = (dummy[k] and 0 or 1e9) + x.ends
            if not best or rank < best then gone, best = k, rank end
        end
        if gone then m[gone] = nil end
    end
    m[key] = { name = spell.en, status = spell.status, at = clock(), ends = clock() + length(key, troub), troub = troub,
               sv = util.has_buff(player.buffs, 52) }
    state.song_sung = state.song_sung or {}
    state.song_sung[key] = clock()
end

-- Sung less than 15 s ago and gone again: the game isn't keeping it (more songs than slots, another bard's songs...).
-- Not sung again for a minute, and said, instead of looping (seen 2026-10-18: the same 3 songs every 6 s for minutes).
local function bounced(name, player)
    local k = name:lower()
    local t = (state.song_sung or {})[k]
    if not t or clock() - t > 15 or on(name) then return false end
    state.song_hold = state.song_hold or {}
    if not state.song_hold[k] or clock() > state.song_hold[k] then
        state.song_hold[k] = clock() + 60
        h.log(('Songs: %s dropped off right after it was sung - waiting a minute (check "How many songs" and the dummy songs)'):format(name))
    end
    return true
end
local function held(name) local t = (state.song_hold or {})[name:lower()] return t and clock() < t end

-- a song effect wore off us or was dispelled ('action message' 64 / 204 / 206 / 350 / 531, param = the buff)
function bard.on_lost(buff_id)
    local m = mine()
    local key = shortest(m, buff_id)
    if key then m[key] = nil end
end

-- What's on now, for the app / tests: { {name, left, troub}, ... }, least time left first
function bard.current()
    local out = {}
    for _, x in pairs(mine()) do out[#out + 1] = { name = x.name, left = math.floor(x.ends - clock()), troub = x.troub } end
    table.sort(out, function(a, b) return a.left < b.left end)
    return out
end

------------------------------------------------------------------------
-- The game's timers for our own buffs (incoming 0x063, part 9 - read only, nothing is sent): the real length of each
-- song (gear, merits, Troubadour), songs gone without a message, and songs already up that Vanguard didn't sing (by
-- hand, another addon, before a reload) - picked up where they are (his request 2026-10-18).
------------------------------------------------------------------------
local WRAP = 4294967296 / 60                       -- the game's buff clock wraps every ~2.27 years
local ends = {}                                    -- [buff id] = { os.time() it ends, ... }
local seen_buffs, ends_at = false, -100            -- a buff packet came (the game sends one on every buff change)
function bard.on_buff_packet(data)
    if type(data) ~= 'string' or #data < 0xC8 or data:byte(0x05) ~= 0x09 then return end
    local now = os.time()
    local out = {}
    for i = 0, 31 do
        local id = data:unpack('H', 0x08 + 2 * i + 1)
        local raw = data:unpack('I', 0x48 + 4 * i + 1)
        if id and id ~= 0 and id ~= 255 and raw and raw > 0 then
            local t = 1009810800 + raw / 60
            t = t + math.floor((now - t) / WRAP + 0.5) * WRAP          -- the wrap that lands nearest to now
            if t > now and t - now < 3600 then
                out[id] = out[id] or {}
                out[id][#out[id] + 1] = t
            end
        end
    end
    ends, seen_buffs, ends_at = out, true, clock()
end
-- after a reload: the last buff packet the game sent
function bard.read_last_buffs()
    local ok, data = pcall(function() return windower.packets and windower.packets.last_incoming and windower.packets.last_incoming(0x063) end)
    if ok and data then bard.on_buff_packet(data) end
end

local function reconcile(player, wanted)
    local m = mine()
    local have = {}
    for _, b in pairs(player.buffs or {}) do have[b] = (have[b] or 0) + 1 end
    local now = os.time()
    local by = {}
    for k, x in pairs(m) do
        if x.status then by[x.status] = by[x.status] or {} table.insert(by[x.status], k) end
    end
    for status, keys in pairs(by) do
        -- the real time of songs just sung (the newest song has the longest timer)
        if ends[status] then
            local lefts = {}
            for _, t in ipairs(ends[status]) do lefts[#lefts + 1] = t - now end
            table.sort(lefts, function(a, b) return a > b end)
            table.sort(keys, function(a, b) return m[a].at > m[b].at end)
            for i, k in ipairs(keys) do
                local x = m[k]
                if lefts[i] and not x.learned and clock() - x.at < 30 and ends_at >= x.at then
                    local real = (clock() - x.at) + lefts[i]
                    if real > 30 and real < 3600 then
                        x.ends, x.learned = clock() + lefts[i], true
                        state.song_base = state.song_base or {}
                        state.song_base[k] = real / (x.troub and 2 or 1)
                    end
                end
            end
        end
        -- fewer of these buffs than our songs: one wore off / was dispelled without a message we saw
        local n = have[status] or 0
        if seen_buffs and n < #keys then
            table.sort(keys, function(a, b) return m[a].ends < m[b].ends end)
            for i = 1, #keys - n do
                if clock() - m[keys[i]].at > 6 then m[keys[i]] = nil end
            end
        end
    end
    -- songs in the list that are up but weren't sung by Vanguard: picked up with the game's time left
    local groups = {}
    for _, name in ipairs(wanted) do
        local sp = util.spell(name)
        if sp and sp.status then groups[sp.status] = groups[sp.status] or {} table.insert(groups[sp.status], sp.en) end
    end
    local room = (bard.slots(player)) - count(m)
    for status, names in pairs(groups) do
        local ours, missing = 0, {}
        for _, x in pairs(m) do if x.status == status then ours = ours + 1 end end
        for _, n in ipairs(names) do if not m[n:lower()] then missing[#missing + 1] = n end end
        local extra = (have[status] or 0) - ours
        if extra > 0 and #missing > 0 and room > 0 then
            local lefts = {}
            for _, t in ipairs(ends[status] or {}) do lefts[#lefts + 1] = t - now end
            for _, x in pairs(m) do                    -- take out the timers that are our own songs
                if x.status == status then
                    local mine_left, best = x.ends - clock(), nil
                    for i, l in ipairs(lefts) do if not best or math.abs(l - mine_left) < math.abs(lefts[best] - mine_left) then best = i end end
                    if best then table.remove(lefts, best) end
                end
            end
            table.sort(lefts)                          -- the shortest first: never later than the song really ends
            for i = 1, math.min(extra, #missing, room) do
                local n = missing[i]
                local len = tonumber(S.songs.duration) or 240
                local rest = lefts[i] or len / 2       -- no timer from the game yet: assume half
                m[n:lower()] = { name = n, status = status, at = clock() - math.max(0, len - rest), ends = clock() + rest,
                                 troub = rest > len * 1.1, learned = true }
                room = room - 1
                h.log(('Songs: %s is already up (%s) - picking up from there'):format(n,
                    lefts[i] and ('%ds left'):format(math.floor(rest)) or 'time left unknown'))
            end
        end
    end
end

-- Does this song need singing now? Not on; running low ("Sing again this long before they wear"); Troubadour is up
-- and it wasn't sung under it (as Singer); or sung before a NiTro / "Sing all songs again now" that isn't finished.
local function needs(name, troub_up, sv_up)
    local x = on(name)
    if not x then return true end
    if x.ends - clock() <= (tonumber(S.songs.refresh_before) or 30) then return true end
    if troub_up and not x.troub then return true end
    -- Soul Voice doubles songs sung while it's up: the songs already on are sung again under it (Singer)
    if sv_up and not x.sv then return true end
    if state.redo_at and x.at < state.redo_at then return true end
    return false
end

-- One song (or Marcato / NiTro / a dummy) if something is due. Returns true when it acted.
function bard.sing(player)
    local wanted, slots, base = bard.wanted(player)
    if #wanted == 0 then return false end
    reconcile(player, wanted)
    local troub_up = util.has_buff(player.buffs, 348)
    local sv_up = util.has_buff(player.buffs, 52)
    local function singable(name)
        local sp = util.spell(name)
        return sp and util.can_cast(sp, player) and sp
    end
    local due = {}
    for _, name in ipairs(wanted) do
        if needs(name, troub_up, sv_up) and not held(name) and not bounced(name, player) then due[#due + 1] = name end
    end
    -- the redo is over when every song it covered was sung again (or after 3 minutes, e.g. out of range all along)
    if state.redo_at then
        local left = false
        for _, name in ipairs(due) do
            local x = on(name)
            if x and x.at < state.redo_at and singable(name) then left = true end
        end
        if not left or clock() - state.redo_at > 180 then state.redo_at = nil end
    end
    if #due == 0 then
        -- NiTro as soon as it's ready in a fight when the songs up weren't sung under Troubadour: they're all sung
        -- again and last twice as long (his request 2026-10-18: "strive to use Nightingale, Troubadour in sync")
        if state.nitro_until then return h.nitro(player, true) end
        if h.nitro_wait and h.nitro_wait(player) == 0 then
            for _, name in ipairs(wanted) do
                local x = on(name)
                if x and not x.troub and singable(name) then return h.nitro(player, true) end
            end
        end
        return false
    end
    local ok, who = bard.in_range()
    if not ok then
        if not h.recently('song_range', 20) then h.mark('song_range') h.log(('Songs: waiting for %s to come within 10\''):format(who)) end
        return false
    end
    if h.nitro(player, true) then return true end
    -- Clarion Call (ticked in the abilities) right before the songs when the list has a song for its extra slot
    if slots == base and (#list(S.songs.list) > base or (S.songs.clarion_song or '') ~= '') and h.clarion_ok and h.clarion_ok(player) then
        h.log('Clarion Call: +1 song')
        return true
    end
    -- NiTro nearly ready and the due songs are still up for longer than that: wait for it instead of singing them
    -- plain now (they'd only last half as long as under Troubadour)
    local wait = h.nitro_wait and h.nitro_wait(player)
    if wait and wait > 0 then
        local soonest = math.huge
        for _, name in ipairs(due) do
            local x = on(name)
            if not x or (state.redo_at and x.at < state.redo_at) then soonest = 0 break end
            soonest = math.min(soonest, x.ends - clock())
        end
        if wait < soonest - 8 then
            if not h.recently('nitro_wait', 30) then h.mark('nitro_wait') h.log(('Songs: waiting %ds for NiTro'):format(math.ceil(wait))) end
            return false
        end
    end
    -- songs this bard can't sing (not learned, or not a song): skipped, and said once in a while - a friend's bard
    -- sang 3 of 4 songs and no dummies without a word about why (2026-10-18)
    local function can_sing(name)
        local sp = util.spell(name)
        if sp and util.can_cast(sp, player) then return sp end
        if not h.recently('song_skip:' .. name:lower(), 600) then
            h.mark('song_skip:' .. name:lower())
            h.log(('Songs: %s skipped - %s'):format(name, sp and "it isn't learned on this character" or "that isn't a song name"))
        end
        return nil
    end
    local real = {}
    for _, name in ipairs(wanted) do if can_sing(name) then real[#real + 1] = name end end
    local dummies = {}
    for _, d in ipairs(list(S.songs.dummy)) do if can_sing(d) then dummies[#dummies + 1] = d end end
    -- Dummy songs, exactly as Singer: the harp's extra slots only open while they hold a song, so when our songs on
    -- us number slots - i (and the list has more to sing), dummy i goes in first - with 4 slots and 2 dummies: the
    -- first 2 songs, dummy 2, dummy 1, then the 3rd and 4th songs replace the dummies (least time left). With every
    -- slot still full (a refresh, NiTro) no dummies: each song replaces itself.
    local cur = count(mine())
    if base > 2 and cur < slots and #real > cur then
        for i = 1, math.min(#dummies, slots - 2) do
            if base - i >= 0 and cur == slots - i then
                local sp = util.spell(dummies[i])
                if sp and util.spell_ready(sp, player) and h.try_cast(sp.en, '<me>', 'dummy song (opens a slot)', player) then return true end
            end
        end
    end
    for _, name in ipairs(due) do
        local sp = util.spell(name)
        if sp and util.can_cast(sp, player) and util.spell_ready(sp, player) then
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
-- Songs on party members (Pianissimo songs, and the party songs that reach them), kept like our own (Singer keeps a
-- timer list per target): added when the song LANDS on them (it used to count from the start of the cast, so an
-- interrupted or out-of-range song left them without it for minutes), its real length (learned song lengths,
-- Troubadour), sung again under NiTro, and forgotten when it wears off or they're KO'd (2026-10-19 BARD round).
-- state.pmine[member][song] = { name, status, at, ends, troub }
------------------------------------------------------------------------
local function pm(name)
    state.pmine = state.pmine or {}
    local k = name:lower()
    state.pmine[k] = state.pmine[k] or {}
    local t = clock()
    for s, x in pairs(state.pmine[k]) do if x.ends <= t then state.pmine[k][s] = nil end end
    return state.pmine[k]
end

function bard.on_member_song(spell, name, player)
    local m = pm(name)
    local key = spell.en:lower()
    local troub = util.has_buff(player.buffs, 348)
    if not m[key] and count(m) >= (bard.slots(player)) then
        local gone = shortest(m)
        if gone then m[gone] = nil end
    end
    m[key] = { name = spell.en, status = spell.status, at = clock(), ends = clock() + length(key, troub), troub = troub,
               sv = util.has_buff(player.buffs, 52) }
    state.ppending = state.ppending or {}
    state.ppending[key .. '>' .. name:lower()] = nil
end
function bard.on_member_lost(name, buff_id)
    local m = pm(name)
    local key = shortest(m, buff_id)
    if key then m[key] = nil end
end
function bard.on_member_ko(name) if state.pmine then state.pmine[name:lower()] = nil end end

-- Does <name> need this song (Pianissimo)? Not on them; running low; Troubadour up and not sung under it. A cast
-- started in the last 12 s is waited for (it lands, or it didn't and we try again).
function bard.member_needs(spell, name, player, buffs)
    local pk = spell.en:lower() .. '>' .. name:lower()
    local pend = (state.ppending or {})[pk]
    if pend and clock() < pend then return false end
    local x = pm(name)[spell.en:lower()]
    -- after a reload the bard knew none of its Pianissimo songs and sang them all again: one the member is already
    -- showing (party buff icons) is picked up once, as if half done (2026-10-19 BARD round)
    state.pseen = state.pseen or {}
    if not x and not state.pseen[pk] and spell.status and buffs and util.has_buff(buffs, spell.status) then
        local len = tonumber(S.songs.duration) or 240
        x = { name = spell.en, status = spell.status, at = clock() - len / 2, ends = clock() + len / 2, troub = false }
        pm(name)[spell.en:lower()] = x
        h.log(('Songs: %s is already on %s - picking up from there'):format(spell.en, name))
    end
    state.pseen[pk] = true
    if not x then return true end
    if x.ends - clock() <= (tonumber(S.songs.refresh_before) or 30) then return true end
    if util.has_buff(player.buffs, 348) and not x.troub then return true end
    if util.has_buff(player.buffs, 52) and not x.sv then return true end
    return false
end
function bard.member_cast(spell, name)
    state.ppending = state.ppending or {}
    state.ppending[spell.en:lower() .. '>' .. name:lower()] = clock() + 12
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
        if util.is_player(m) and m.name and util.dist(m) <= 30 then add(m.name) end
    end
    table.sort(out)
    return out
end

-- What the panel shows.
function bard.info(player)
    local slots, base = bard.slots(player)
    local _, harp = bard.instrument()
    local map = bard.pian_map()
    -- the songs on the bard now and on members (Pianissimo), with the time left - shown on the Songs tab
    local members = {}
    for who, songs in pairs(state.pmine or {}) do
        for _, x in pairs(songs) do
            local left = math.floor(x.ends - clock())
            if left > 0 then members[#members + 1] = { who = who, name = x.name, left = left, troub = x.troub } end
        end
    end
    table.sort(members, function(a, b) return a.left < b.left end)
    return { slots = slots, base = base, instrument = harp or 'none', auto = (tonumber(S.songs.slots) or 0) < 2,
             pianissimo = map, candidates = bard.candidates(player), on_now = bard.current(), on_members = members }
end

function bard.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return bard
