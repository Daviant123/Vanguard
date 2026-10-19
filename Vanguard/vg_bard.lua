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

-- still up by Vanguard's timer
local function up_raw(name)
    local last = state.songs[name:lower()]
    local len = (state.song_len or {})[name:lower()] or S.songs.duration
    return last and clock() - last < len
end
-- sung before NiTro started while Troubadour is up: to be sung again, so it lasts twice as long
local troub_up = false
local function stale(name)
    local last = state.songs[name:lower()]
    return troub_up and state.nitro_at and last ~= nil and last < state.nitro_at
end
local function active(name) return up_raw(name) and not stale(name) end

------------------------------------------------------------------------
-- Songs already up that Vanguard didn't sing (sung by hand before Vanguard was on, by another addon, or before a
-- reload): picked up where they are instead of all sung again (user request 2026-10-18). The game sends this
-- character's buffs with their end times (incoming 0x063, part 9); Vanguard only reads it, nothing is sent.
------------------------------------------------------------------------
local WRAP = 4294967296 / 60                       -- the game's buff clock wraps every ~2.27 years
local ends = {}                                    -- [buff id] = { os.time() it ends, ... }
local seen_buffs, ends_at = false, -100                           -- a buff packet came (the game sends one on every buff change)
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

local function adopt(player, wanted)
    local count = {}
    for _, b in pairs(player.buffs or {}) do count[b] = (count[b] or 0) + 1 end
    local groups = {}                              -- songs giving the same buff (Victory / Honor / Advancing March)
    for _, name in ipairs(wanted) do
        local sp = util.spell(name)
        if sp and sp.status then
            groups[sp.status] = groups[sp.status] or {}
            table.insert(groups[sp.status], name)
        end
    end
    local now = os.time()
    for status, names in pairs(groups) do
        local have = count[status] or 0
        local up, missing = {}, {}
        for _, n in ipairs(names) do if up_raw(n) then up[#up + 1] = n else missing[#missing + 1] = n end end
        -- the real length of a song Vanguard just sang (gear, merits and Troubadour change it): from the game's timer
        if ends[status] and #up > 0 then
            local fresh, left = {}, {}
            for _, n in ipairs(up) do
                local last = state.songs[n:lower()]
                if clock() - last < 30 and ends_at >= last and state.song_learned[n:lower()] ~= last then fresh[#fresh + 1] = n end
            end
            if #fresh > 0 then
                for _, t in ipairs(ends[status]) do left[#left + 1] = t - now end
                table.sort(left, function(a, b) return a > b end)
                table.sort(fresh, function(a, b) return state.songs[a:lower()] > state.songs[b:lower()] end)
                for i, n in ipairs(fresh) do
                    if left[i] then
                        local last = state.songs[n:lower()]
                        state.song_len[n:lower()] = (clock() - last) + left[i]
                        state.song_learned[n:lower()] = last
                    end
                end
            end
        end
        if have < #up and seen_buffs then
            -- fewer of these buffs than songs Vanguard thinks are up: one wore off early or was dispelled - forget
            -- the oldest (not one sung in the last few seconds: the buff shows a moment after the song)
            table.sort(up, function(a, b) return state.songs[a:lower()] < state.songs[b:lower()] end)
            for i = 1, #up - have do
                if clock() - state.songs[up[i]:lower()] > 6 then state.songs[up[i]:lower()] = nil end
            end
        elseif have > #up and #missing > 0 then
            -- up, but not sung by Vanguard: take the timers of the buffs not matched to songs Vanguard sang
            local left = {}
            for _, t in ipairs(ends[status] or {}) do left[#left + 1] = t - now end
            for _, n in ipairs(up) do
                local mine = (state.song_len[n:lower()] or S.songs.duration) - (clock() - state.songs[n:lower()])
                local best
                for i, l in ipairs(left) do if not best or math.abs(l - mine) < math.abs(left[best] - mine) then best = i end end
                if best then table.remove(left, best) end
            end
            table.sort(left)                       -- the shortest first: never later than the song really ends
            for i = 1, math.min(have - #up, #missing) do
                local n = missing[i]
                local len = S.songs.duration
                local rest = left[i] and math.min(left[i], len) or len / 2   -- no timer from the game: assume half
                if left[i] and left[i] > len then len, rest = left[i], left[i] end        -- sung under Troubadour
                state.songs[n:lower()] = clock() - (len - rest)
                state.song_len[n:lower()] = len
                state.song_troub[n:lower()] = rest > S.songs.duration * 1.1
                h.log(('Songs: %s is already up (%s) - picking up from there'):format(n,
                    left[i] and ('%ds left'):format(math.floor(rest)) or 'time left unknown'))
            end
        end
    end
end

-- One song (or Marcato / a dummy) if something is due. Returns true when it acted.
function bard.sing(player)
    state.song_len, state.song_troub, state.song_learned = state.song_len or {}, state.song_troub or {}, state.song_learned or {}
    local wanted, slots, base = bard.wanted(player)
    if #wanted == 0 then return false end
    troub_up = util.has_buff(player.buffs, 348)
    adopt(player, wanted)
    local due = {}
    for _, name in ipairs(wanted) do
        local last = state.songs[name:lower()]
        local keep = (state.song_len[name:lower()] or S.songs.duration) - S.songs.refresh_before
        if not last or clock() - last > keep or stale(name) then due[#due + 1] = name end
    end
    if #due == 0 then
        -- NiTro as soon as it's ready in a fight when the songs up weren't sung under Troubadour: they're all sung
        -- again and last twice as long (his request 2026-10-18: "strive to use Nightingale, Troubadour in sync")
        if state.nitro_until then return h.nitro(player, true) end
        if h.nitro_wait and h.nitro_wait(player) == 0 then
            for _, name in ipairs(wanted) do
                if active(name) and not state.song_troub[name:lower()] and util.can_cast(util.spell(name) or {}, player) then
                    return h.nitro(player, true)
                end
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
    -- NiTro nearly ready and the due songs are still up for longer than that: wait for it instead of singing them
    -- plain now (they'd only last half as long as under Troubadour)
    local wait = h.nitro_wait and h.nitro_wait(player)
    if wait and wait > 0 then
        local soonest = math.huge
        for _, name in ipairs(due) do
            local last = state.songs[name:lower()]
            if not last or stale(name) then soonest = 0 break end
            soonest = math.min(soonest, (state.song_len[name:lower()] or S.songs.duration) - (clock() - last))
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
    -- Dummy songs (Singer's order): with 3+ slots and K dummies (at most slots - 2), the first slots - K real songs,
    -- then the dummies (last one first) in the slots still free, then the remaining real songs go over them. Worked out
    -- from the songs this bard can actually sing (it used to count songs, and one real song that couldn't be sung threw
    -- the count off - the dummies were skipped).
    local dummies = {}
    for _, d in ipairs(list(S.songs.dummy)) do if can_sing(d) then dummies[#dummies + 1] = d end end
    local k = math.min(#dummies, slots - 2)
    if base > 2 and k > 0 and #real > slots - k then
        local first = slots - k
        local ready, up, later_due = true, 0, false
        for i, name in ipairs(real) do
            if active(name) then up = up + 1
            elseif i <= first then ready = false
            else later_due = true end
        end
        for i = 1, k do if active(dummies[i]) then up = up + 1 end end
        if ready and later_due and up < slots then
            for i = k, 1, -1 do
                if not active(dummies[i]) then
                    if h.try_cast(dummies[i], '<me>', 'dummy song (opens a slot)', player) then return true end
                end
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
    return { slots = slots, base = base, instrument = harp or 'none', auto = (tonumber(S.songs.slots) or 0) < 2,
             pianissimo = map, candidates = bard.candidates(player) }
end

function bard.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return bard
