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
-- reloaded mid-song (an update, //lua r): the game ignores a cast sent before the last one finishes, so no song for a
-- few seconds after loading (his log 2026-10-19: Honor March sent at once after each reload, ignored, sent 11 s later)
local loaded_at = clock()

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

local function list(str) return util.split(str or '', ',') end

function bard.slots(player)
    local base = tonumber(S.songs.slots) or 0
    if base < 2 then base = bard.instrument() end
    -- an instrument gives at most 4; the 5th only while Clarion Call is up. "5 songs" picked by hand without it had the
    -- bard singing a 5th song that knocked another off, round and round (2026-10-18)
    base = math.min(base, 4)
    -- the harp's extra slots only open while each holds a song sung with the harp - a dummy song (Singer's rule): with
    -- fewer dummies than extra slots, only 2 + the dummies can be kept. Counting the harp's 4 with no / one dummy had
    -- every extra song knock another off, 180+ songs in half an hour (found by the bard fuzz test, 2026-10-19)
    if base > 2 then
        local n = 0
        for _, d in ipairs(util.split(S.songs.dummy or '', ',')) do
            local sp = util.spell(d)
            if sp and util.can_cast(sp, player) then n = n + 1 end
        end
        if 2 + n < base then
            if h and h.recently and not h.recently('song_dummies', 900) then
                h.mark('song_dummies')
                h.log(('Songs: %d song slots need %d dummy song%s (Songs tab) - singing %d songs until then'):format(
                    base, base - 2, base - 2 == 1 and '' or 's', 2 + n))
            end
            base = 2 + n
        end
    end
    local extra = util.has_buff(player.buffs, 499) and 1 or 0          -- Clarion Call
    -- the extra slot stays open after Clarion Call wears off as long as its song is kept up (bg-wiki: "keep re-singing
    -- the Clarion Call song before it expires") - counted only while the buff was up, the 5th song dropped 3 minutes
    -- later and stayed off (his report 2026-10-19: "struggles to keep the 5th song up")
    if extra == 0 then
        local n, t = 0, clock()
        for _, x in pairs(state and state.mysongs or {}) do if x.ends > t then n = n + 1 end end
        if n > base then extra = 1 end
    end
    return base + extra, base
end

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

-- Learned song lengths are kept in the settings (songs.learned = "honor march=330;valor minuet v=300"), so a reload
-- or an update doesn't go back to the "Songs last" slider until each song is sung again (2026-10-19 BARD round).
local function load_learned()
    if state.song_base then return end
    state.song_base = {}
    for _, part in ipairs(util.split(tostring(S.songs.learned or ''), ';')) do
        local k, v = part:match('^%s*(.-)%s*=%s*(%d+)%s*$')
        if k and tonumber(v) then state.song_base[k:lower()] = tonumber(v) end
    end
end
local function store_learned()
    local keys = {}
    for k in pairs(state.song_base or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = ('%s=%d'):format(k, math.floor(state.song_base[k] + 0.5)) end
    local text = table.concat(parts, ';')
    if text ~= S.songs.learned then
        S.songs.learned = text
        if h.save then h.save() end
    end
end
-- the learned lengths, for the app: { {name, secs}, ... }
function bard.learned()
    load_learned()
    local out = {}
    for k, v in pairs(state.song_base) do out[#out + 1] = { name = k, secs = math.floor(v + 0.5) } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- how long a song sung now lasts: learned from the game's timer for that song, else the "Songs last" setting
local function length(key, troub)
    load_learned()
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
-- (the message doesn't say whose song it was: another bard's Minuet wearing off us took ours away and it was sung again
-- early - only one of ours due to end about now counts; found by the simulator with a 2nd bard)
function bard.on_lost(buff_id)
    local m = mine()
    local key = shortest(m, buff_id)
    if not key then return end
    local ours, up = 0, 0
    for _, x in pairs(m) do if x.status == buff_id then ours = ours + 1 end end
    local p = windower.ffxi.get_player()
    for _, b in pairs(p and p.buffs or {}) do if b == buff_id then up = up + 1 end end
    -- ours if one was due about now, or if fewer of that buff are left than songs we think we have
    if math.abs(m[key].ends - clock()) < 15 or up < ours then m[key] = nil end
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
-- seconds left on one of our buffs by the game's timer (the soonest if several), or nil (Aftermath upkeep uses it)
function bard.buff_left(id)
    local best
    for _, t in ipairs(ends[id] or {}) do if not best or t < best then best = t end end
    return best and (best - os.time()) or nil
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
        -- the game's timers for this buff, matched to our songs by what each is expected to have left (two Minuets
        -- share one buff; "the newest has the longest timer" swapped them when the older one was a Troubadour song -
        -- found by the bard fuzz test, 2026-10-19). A song sung in the last 30 s takes its real time (and length).
        if ends[status] then
            local lefts = {}
            for _, t in ipairs(ends[status]) do lefts[#lefts + 1] = t - now end
            -- songs whose time is known (learned) first, closest match; then the ones just sung take what's left,
            -- the newest the longest (their expected time may still be the slider's guess)
            local cand = {}
            for _, k in ipairs(keys) do
                if m[k].learned then
                    for i, l in ipairs(lefts) do cand[#cand + 1] = { k = k, i = i, d = math.abs((m[k].ends - clock()) - l) } end
                end
            end
            table.sort(cand, function(a, b) return a.d < b.d end)
            local used, got = {}, {}
            for _, c in ipairs(cand) do
                if c.d <= 15 and not used[c.i] and not got[c.k] then used[c.i], got[c.k] = true, lefts[c.i] end
            end
            -- just sung: the free timer closest to what it should have (its learned length minus the seconds since it
            -- landed) - "the longest" took another bard's newer Minuet on us (found by the simulator with a 2nd bard)
            local cand2 = {}
            for _, k in ipairs(keys) do
                -- (only songs whose timer isn't known yet: a known one with no close timer is gone - it took another
                -- bard's March after ours was dispelled; found by the bard fuzz test)
                if m[k] and not got[k] and not m[k].learned then
                    local want = length(k, m[k].troub) - (clock() - m[k].at)
                    for i, l in ipairs(lefts) do
                        if not used[i] then cand2[#cand2 + 1] = { k = k, i = i, d = math.abs(want - l) } end
                    end
                end
            end
            table.sort(cand2, function(a, b) return a.d < b.d end)
            for _, c in ipairs(cand2) do
                if not used[c.i] and not got[c.k] then used[c.i], got[c.k] = true, lefts[c.i] end
            end
            -- a song of ours with no timer left for it (a timer update came since it landed) is gone - dispelled, or
            -- replaced without a message; counting buffs can't tell when another bard's songs share the buff, and a
            -- song dispelled before its timer was read used to stay "on" for minutes (found by the simulator)
            for _, k in ipairs(keys) do
                local x = m[k]
                if x and not got[k] and ends_at > x.at and clock() - x.at > 6 then m[k] = nil end
            end
            for _, k in ipairs(keys) do
                local x, l = m[k], got[k]
                if x and l and not x.learned and clock() - x.at < 30 and ends_at >= x.at then
                    local real = (clock() - x.at) + l
                    if real > 30 and real < 3600 then
                        x.ends, x.learned = clock() + l, true
                        load_learned()
                        local before = state.song_base[k]
                        state.song_base[k] = real / (x.troub and 2 or 1)
                        if not before or math.abs(before - state.song_base[k]) >= 5 then store_learned() end
                    end
                end
            end
        end
        -- no timers for this buff at all (none of it is up): fewer buffs than our songs - one wore off / was dispelled
        local n = have[status] or 0
        if seen_buffs and not ends[status] and n < #keys then
            -- which one went: the game's timers say how long each one left has - match them, the song without a match
            -- is gone (two Minuets share one buff; guessing "the one with least time" re-sang the wrong one after a
            -- dispel - found by the bard simulator, 2026-10-19). Without timers: the one with least time left.
            local gone = {}
            local lefts = {}
            for _, t in ipairs(ends[status] or {}) do lefts[#lefts + 1] = t - now end
            if #lefts == n and n > 0 then
                local free = {}
                for i = 1, #lefts do free[i] = true end
                local pairs_ = {}
                for _, k in ipairs(keys) do
                    for i, l in ipairs(lefts) do pairs_[#pairs_ + 1] = { k = k, i = i, d = math.abs((m[k].ends - clock()) - l) } end
                end
                table.sort(pairs_, function(a, b) return a.d < b.d end)
                local matched = {}
                for _, p in ipairs(pairs_) do
                    if free[p.i] and not matched[p.k] then free[p.i], matched[p.k] = false, true end
                end
                for _, k in ipairs(keys) do if not matched[k] then gone[#gone + 1] = k end end
            else
                table.sort(keys, function(a, b) return m[a].ends < m[b].ends end)
                for i = 1, #keys - n do gone[#gone + 1] = keys[i] end
            end
            for _, k in ipairs(gone) do
                if clock() - m[k].at > 6 then m[k] = nil end
            end
        end
    end
    -- songs in the list that are up but weren't sung by Vanguard: picked up with the game's time left - only just after
    -- loading (songs sung before Vanguard was on / a reload); later, a song of ours that's missing while the same buff
    -- is up is another bard's song, and adopting it left ours unsung (found by the simulator with a 2nd bard)
    if clock() - loaded_at > 90 then return end
    local groups = {}
    for _, name in ipairs(wanted) do
        local sp = util.spell(name)
        if sp and sp.status then groups[sp.status] = groups[sp.status] or {} table.insert(groups[sp.status], sp.en) end
    end
    -- (+1: the Clarion Call slot may be open with nothing of ours counted yet - right after a reload)
    local room = (bard.slots(player)) + 1 - count(m)
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
                -- picked up while Troubadour / Soul Voice is up: count it as sung under them (after a reload during
                -- Soul Voice every song was sung again - his log 2026-10-19)
                m[n:lower()] = { name = n, status = status, at = clock() - math.max(0, len - rest), ends = clock() + rest,
                                 troub = rest > len * 1.1 or util.has_buff(player.buffs, 348),
                                 sv = util.has_buff(player.buffs, 52), learned = true }
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

------------------------------------------------------------------------
-- A party member missing our songs (his request 2026-10-27: "if the bard is singing 4 or 5 songs, and notices someone
-- in the party does not have the songs, it needs to do a dummy song so that the songs can be done correctly").
-- A member who was out of range, zoned, died or was dispelled has fewer of our songs than we do. Singing the missing
-- song again only adds it while they hold under 2 of our songs: past that a song sung without the harp replaces their
-- oldest one. So, like a bard would: a dummy song (sung with the harp, it opens a slot on them), then the missing
-- song (it replaces the dummy on them; on us it's only refreshed). Whatever the dummy knocked off us is sung again by
-- the normal upkeep right after (missing songs go first). Songs are compared by their buff (every Minuet shares one
-- icon), from the party buff icons (0x076). Only members within 10' and alive; a member's gap must show for 6 s, and
-- a member who still misses one after 3 tries is left for 5 minutes.
------------------------------------------------------------------------
local REACH = 10
local function member_gaps(player, wanted, dummyset, slots)
    -- our real songs that are on, by buff id (in list order)
    local ours, by_status, total = {}, {}, 0
    for _, name in ipairs(wanted) do
        local x = on(name)
        if x and x.status and not dummyset[name:lower()] then
            ours[#ours + 1] = x
            by_status[x.status] = by_status[x.status] or {}
            table.insert(by_status[x.status], x)
            total = total + 1
        end
    end
    if total == 0 then return nil end
    local party = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        local m = party[k]
        local mob = m and m.mob
        local buffs = mob and state.party_buffs and state.party_buffs[mob.id]
        if mob and buffs and (m.hpp or mob.hpp or 0) > 0 and util.dist(mob) <= REACH then
            local have = {}
            for _, b in ipairs(buffs) do have[b] = (have[b] or 0) + 1 end
            -- our Pianissimo songs on them use their slots too: that many fewer party songs fit (found by the bard
            -- fuzz test - a Ballad on the leader made it sing the party songs again every 25 s for nothing)
            -- (only the songs set as Pianissimo songs for them: the party songs that reach them are kept in pmine too)
            -- (counted from their buff icons: what we remember can be behind, e.g. after a zone)
            local pian = 0
            local pmap = bard.pian_map()
            local mine_on = (state.pmine or {})[m.name:lower()] or {}
            for key, songs_ in pairs(pmap) do
                if key:lower() == m.name:lower() then
                    for _, sn in ipairs(songs_) do
                        local sp_ = util.spell(sn)
                        if mine_on[sn:lower()] or (sp_ and sp_.status and have[sp_.status]) then pian = pian + 1 end
                    end
                end
            end
            -- (they hold as many of our songs as we do - the same casts reach them - less those Pianissimo songs)
            -- and without dummy songs (the harp's slots) nobody holds more than 2 of a bard's songs - another bard's
            -- songs (same icons) made our count look bigger in the fuzz test
            local cap = (next(dummyset) ~= nil and (slots or total) > 2) and total or math.min(total, 2)
            local room = math.max(0, cap - pian)
            -- which of a kind they lack (every Minuet shows the same icon): they most likely hold the ones sung
            -- first and missed the later ones; a try that didn't help moves on to the next of that kind
            local g = (state.song_gap or {})[m.name] or {}
            local held, missing = 0, nil
            local used = {}
            for _, x in ipairs(ours) do
                local st = x.status
                local list_ = by_status[st]
                table.sort(list_, function(a, b) return a.at < b.at end)
                local n_have = math.min(have[st] or 0, #list_)
                local rank = 0
                for i_, y in ipairs(list_) do if y == x then rank = i_ end end
                if rank <= n_have then
                    held = held + 1
                elseif not missing then
                    missing = x.name
                    local extra = #list_ - n_have
                    if extra > 1 and (g.n or 0) > 0 then              -- (rotate among the ones of that kind)
                        local pick = n_have + 1 + ((g.n or 0) % extra)
                        missing = list_[pick].name
                    end
                end
            end
            if missing and held < room then return m.name, missing, held, room end
        end
    end
    return nil
end

local function member_repair(player, wanted, base, dummies, slots)
    local dummyset = {}
    for _, d in ipairs(dummies) do dummyset[d:lower()] = true end
    local who, song, held, room = member_gaps(player, wanted, dummyset, slots)
    state.song_gap = state.song_gap or {}
    if not who then
        state.song_gap_seen = nil
        return false
    end
    local g = state.song_gap[who] or { n = 0, last = -100, held = held }
    state.song_gap[who] = g
    -- (only tries that didn't help count: a member missing all 4 songs needs 4 of them)
    if held > (g.held or 0) then g.n = 0 end
    g.held = held
    if g.n >= 3 and clock() - g.last < 300 then return false end      -- tried 3 times: leave it a while
    if g.n >= 3 then g.n = 0 end
    -- the gap must still be there a few seconds later (the party icons come in a moment after a song lands)
    local seen = state.song_gap_seen
    if not seen or seen.who ~= who or seen.song ~= song then
        state.song_gap_seen = { who = who, song = song, t = clock() }
        return false
    end
    if clock() - seen.t < 6 or clock() - g.last < 12 then return false end
    local sp = util.spell(song)
    if not (sp and util.can_cast(sp, player) and util.spell_ready(sp, player)) then return false end
    g.n, g.last = g.n + 1, clock()
    state.song_gap_seen = nil
    -- 2+ of our songs on them already: a dummy (with the harp) first, so the missing song has a slot on them
    if held >= 2 and base > 2 and #dummies > 0 then
        local d = util.spell(dummies[1])
        if d and util.spell_ready(d, player) then
            state.song_repair = { song = sp.en, who = who, t = clock() }
            h.log(('Songs: %s is missing %s (has %d of our %d songs) - a dummy song first (opens a slot on them), then %s'):format(who, sp.en, held, room, sp.en))
            return h.try_cast(d.en, '<me>', 'dummy song (for ' .. who .. ')', player)
        end
        return false
    end
    h.log(('Songs: %s is missing %s (has %d of our %d songs) - singing it again'):format(who, sp.en, held, room))
    return h.try_cast(sp.en, '<me>', 'song (for ' .. who .. ')', player)
end

-- One song (or Marcato / NiTro / a dummy) if something is due. Returns true when it acted.
function bard.sing(player)
    local wanted, slots, base = bard.wanted(player)
    if #wanted == 0 then return false end
    -- after a reload the Clarion Call song (the 5th) is picked up too: picking up only the first 4 left its slot
    -- counted as closed and the 5th song was never sung again (his log 2026-10-19, 19:19)
    local pickup = wanted
    if slots == base then
        local songs = list(S.songs.list)
        local extra = (S.songs.clarion_song or '') ~= '' and S.songs.clarion_song or songs[base + 1]
        if extra then
            pickup = {}
            for _, n in ipairs(wanted) do pickup[#pickup + 1] = n end
            pickup[#pickup + 1] = extra
        end
    end
    reconcile(player, pickup)
    -- just reloaded with songs already on (mid-session - maybe mid-cast): a few seconds' wait
    if clock() - loaded_at < 4 and next(mine()) ~= nil then return false end
    -- a member's missing song after its dummy (member_repair): that song now, then the usual upkeep
    local rep_ = state.song_repair
    if rep_ then
        if clock() - rep_.t > 25 then
            state.song_repair = nil
        else
            local sp = util.spell(rep_.song)
            if sp and util.spell_ready(sp, player) then
                state.song_repair = nil
                return h.try_cast(sp.en, '<me>', 'song (for ' .. rep_.who .. ')', player)
            end
            return false                                    -- (its recast: wait for it, don't sing others in between)
        end
    end
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
    -- songs that are on: the one closest to running out first (in list order a NiTro refresh reached the 5th song after
    -- it had run out - and with it the Clarion Call slot; his report 2026-10-19); missing songs first, in list order
    do
        local order = {}
        for i, n in ipairs(due) do order[n] = i end
        table.sort(due, function(a, b)
            local xa, xb = on(a), on(b)
            if (xa == nil) ~= (xb == nil) then return xa == nil end
            if xa and xb and xa.ends ~= xb.ends then return xa.ends < xb.ends end
            return order[a] < order[b]
        end)
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
        -- a party member missing some of our songs (out of range, zoned, KO'd, dispelled): dummy + the song
        do
            local ok_, _ = bard.in_range()
            local ds = {}
            for _, d in ipairs(list(S.songs.dummy)) do if singable(d) then ds[#ds + 1] = d end end
            if ok_ and S.songs.party_fix ~= false and member_repair(player, wanted, base, ds, slots) then return true end
        end
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
    -- not under Soul Voice: it lasts 3 minutes and the songs are sung again for it now (waiting for NiTro let it run out
    -- with one song sung - found by the bard simulator, 2026-10-19)
    if wait and wait > 0 and not sv_up then
        -- only if NiTro AND singing every song again after it fit before the first one runs out (~4 s a song under
        -- Nightingale, which halves cast and recast times)
        local soonest = math.huge
        for _, name in ipairs(due) do
            local x = on(name)
            if not x or (state.redo_at and x.at < state.redo_at) then soonest = 0 break end
        end
        local n = 0
        for _, name in ipairs(wanted) do
            local x = on(name)
            if x then n = n + 1 soonest = math.min(soonest, x.ends - clock()) end
        end
        if wait + 4 * n + 3 < soonest then
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
    -- dummies must be the songs with the least time left, or the next real song knocks a real one off instead (bg-wiki:
    -- sing them with the harp and no duration gear). His last ~5 min, as long as his songs - after Clarion Call each new
    -- song knocked another off, ~15 casts (his log 2026-10-19, 19:47). Said once an hour, with what to change.
    if #dummies > 0 and not h.recently('song_dummy_long', 3600) then
        load_learned()
        local dl = state.song_base[dummies[1]:lower()]
        local shortest_real
        for _, name in ipairs(real) do
            local l = state.song_base[name:lower()]
            if l and (not shortest_real or l < shortest_real) then shortest_real = l end
        end
        if dl and shortest_real and dl >= shortest_real * 0.8 then
            h.mark('song_dummy_long')
            h.log(('Songs: your dummy songs last %d:%02d - nearly as long as your real songs (%d:%02d). In GearSwap, sing the dummies with the harp and NO song duration gear, or new songs knock real ones off instead of the dummies.'):format(
                math.floor(dl / 60), math.floor(dl % 60), math.floor(shortest_real / 60), math.floor(shortest_real % 60)))
        end
    end
    -- Marcato is up: its song goes first - a dummy now would use Marcato up (found by the bard fuzz test, 2026-10-19)
    local marcato_up = util.has_buff(player.buffs, 231)
    local ms_name = S.songs.marcato_song ~= '' and S.songs.marcato_song or wanted[1]
    local ms_due = false
    for _, n in ipairs(due) do if ms_name and n:lower() == ms_name:lower() then ms_due = true end end
    if base > 2 and cur < slots and #real > cur and not (marcato_up and ms_due) then
        -- (only the harp's extra slots need a dummy: base - 2. Clarion Call's slot takes a song sung without the harp -
        -- with Clarion Call up, a 3rd dummy was sung for nothing every time; his log 2026-10-19)
        for i = 1, math.min(#dummies, base - 2) do
            if base - i >= 0 and cur == slots - i then
                local sp = util.spell(dummies[i])
                if sp and util.spell_ready(sp, player) and h.try_cast(sp.en, '<me>', 'dummy song (opens a slot)', player) then return true end
            end
        end
    end
    if marcato_up and ms_name then                       -- the Marcato song to the front, the rest in their order
        for i, n in ipairs(due) do
            if n:lower() == ms_name:lower() and i > 1 then table.remove(due, i) table.insert(due, 1, n) break end
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
-- Songs come off everyone who zones: forget them all (the members' Pianissimo songs were kept on their old timers and
-- not sung again for minutes after a zone change - 2026-10-19 BARD round)
function bard.on_zone()
    state.mysongs, state.pmine, state.pseen, state.ppending, state.song_hold, state.redo_at = {}, {}, {}, {}, {}, nil
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
    -- the member's buff icons say it's gone (a party song refresh knocked it off - a member holds only 2 songs sung
    -- without the harp, so the two take turns): sing it again now instead of waiting for our estimate (found by the
    -- bard fuzz test: the Ballad was off 25-40 % of the time with short songs, 2026-10-19)
    if x and buffs and spell.status and not util.has_buff(buffs, spell.status) and clock() - x.at > 6 then
        pm(name)[spell.en:lower()] = nil
        x = nil
    end
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
             pianissimo = map, candidates = bard.candidates(player), on_now = bard.current(), on_members = members,
             learned = bard.learned() }
end

function bard.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return bard
