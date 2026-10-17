--[[
Vanguard: farming (rebuilt 2026-10-16 after he asked for farming "impressive and worth praise").

Compared with EasyFarm (target / ignore lists, detection range, waypoints, rest, weapon skill by mob HP), Trust's puller
(camp + leash, return to camp, aggro-only / anything-nearby modes, pull actions with range) and the paid script
clients (MMOMinion grind profiles, DreamBot combat scripts: blacklists, stop conditions, live stats), the old Vanguard
farming chased mobs from wherever it stood, retried unreachable mobs forever and pulled while the healer was empty.
This module:

  Where     area 'camp': mobs within farm.range of a camp spot (set when farming starts, or "Set camp here"), and back
            to the camp after each kill; area 'route': a recorded route walked when nothing is near (loop or back and
            forth). Mobs higher / lower than farm.height are skipped.
  What      mode 'list': the Fight these list (plus anything attacking the party), 'aggro': only what attacks us,
            'any': anything unclaimed nearby that isn't on Leave alone. Claim rule: unclaimed / ours / any.
  Give up   a mob it can't reach is skipped for a while: no closer after 8 s, "Unable to see", "out of range",
            "too far away", "cannot attack", "already claimed" (action messages 4 5 12 78 154 198 217 219 328 446).
  Party     before each pull it waits until the party is ready: everyone at farm.wait_hp % HP, members with MP at
            farm.wait_mp % MP, nobody KO'd or resting, everyone within farm.wait_near yalms (multibox: the alts
            catch up and the healer refills first - EasyFarm, built for one character, can't do this).
  Packs     (round 8) a mob with other mobs standing next to it (farm.pack_range yalms) can bring them along: mobs on
            their own are picked first (farm.packs); farm.pack_strict never pulls one with others next to it.
  Stop      when KO'd, when the inventory is full, after farm.stop_kills kills.
  Stats     run time, kills, kills / hour, a kill every N seconds, mobs skipped; a radar for the app (camp, route,
            mobs coloured by what farming thinks of them, the party).
  Spots     farm spots: everything above saved under a name (zone + mobs) and loaded with one click.

Normal game commands only: /targetbnpc, /attack, the pull command, /heal; walking with windower.ffxi.run.
]]

local util = require('vg_util')
local res = require('resources')

local farm = {}
local S, state, h

local function now() return os.clock() end
local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y return math.sqrt(dx * dx + dy * dy) end
local function list(s) return util.split(s or '', ',') end

local function matches(name, entries)
    name = (name or ''):lower()
    for _, e in ipairs(entries) do if e ~= '' and name:find(e:lower(), 1, true) then return true end end
    return false
end

------------------------------------------------------------------------
-- camp, route
------------------------------------------------------------------------
local function zone() local i = windower.ffxi.get_info() return i and i.zone or 0 end

function farm.camp()
    local x, y, z = (S.farm.camp or ''):match('^(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+)$')
    if not x or tonumber(S.farm.camp_zone) ~= zone() then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

function farm.set_camp(me)
    S.farm.camp = ('%.1f:%.1f:%.1f'):format(me.x, me.y, me.z or 0)
    S.farm.camp_zone = zone()
end

local function route()
    if state.route then return state.route end
    local pts = {}
    for _, p in ipairs(util.split(S.farm.route, ';')) do
        local x, y, z = p:match('^(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+)$')
        if x then pts[#pts + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
    end
    state.route = pts
    return pts
end

local function use_route() return S.farm.area == 'route' and #route() > 0 end

------------------------------------------------------------------------
-- who's in the party (ids for claims; HP / MP for "wait for the party")
------------------------------------------------------------------------
local function party()
    local out, ids = {}, {}
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        local m = p[k]
        if m and m.name then
            out[#out + 1] = m
            if m.mob and m.mob.id then ids[m.mob.id] = true end
        end
    end
    return out, ids
end

-- the reason to wait before pulling (and who, and whether they should rest), or nil when the party is ready.
-- Trusts are left out (they come and go); players with MP are found by having had MP at some point.
function farm.party_wait(player)
    if not S.farm.wait_party then return nil end
    state.farm_maxmp = state.farm_maxmp or {}
    local me = windower.ffxi.get_mob_by_target('me')
    -- keeping a chain going: only real emergencies make it wait
    local chain = farm.chain_running and farm.chain_running()
    local need_hp = chain and math.min(40, S.farm.wait_hp) or S.farm.wait_hp
    local need_mp = chain and math.min(15, S.farm.wait_mp) or S.farm.wait_mp
    for _, m in ipairs((party())) do
        local mob = m.mob
        if (m.mp or 0) > (state.farm_maxmp[m.name] or 0) then state.farm_maxmp[m.name] = m.mp end
        if not (mob and mob.is_npc) then
            if (m.hpp or 100) <= 0 or (mob and (mob.status == 2 or mob.status == 3)) then return m.name .. " is KO'd", m.name end
            if mob and mob.status == 33 then return m.name .. ' (resting)', m.name end
            if (m.hpp or 100) < need_hp then return ('%s (HP %d%%)'):format(m.name, m.hpp), m.name, true end
            if (state.farm_maxmp[m.name] or 0) > 0 and (m.mpp or 100) < need_mp then
                return ('%s (MP %d%%)'):format(m.name, m.mpp), m.name, true
            end
            if m.name ~= player.name and S.farm.wait_near > 0 then
                if not mob or (me and mob.x and dist2(me, mob) > S.farm.wait_near) then return m.name .. ' to catch up', m.name end
            end
        end
    end
    return nil
end

-- low on HP / MP while waiting: rest (the farmer itself), or tell that character to rest (IPC on this PC)
local function rest_for(player, who)
    if who == player.name then
        if not state.resting and player.status == 0 and not h.recently('farm:rest', 8) then
            h.mark('farm:rest')
            windower.send_command('input /heal on')
            state.resting = true
            h.log('Resting before the next pull')
        end
    elseif not h.recently('farm:restcall:' .. who, 20) then
        h.mark('farm:restcall:' .. who)
        windower.send_ipc_message('vg_farmrest ' .. who)
    end
end

-- on the others: the farmer asked this character to rest before the next pull
function farm.on_rest_call(player, who)
    if not player or who:lower() ~= player.name:lower() or player.status ~= 0 or state.resting then return end
    windower.send_command('input /heal on')
    state.resting = true
    h.log('Resting: the farmer waits for me')
end

------------------------------------------------------------------------
-- which mobs
------------------------------------------------------------------------
local function status(s) state.farm_status = s end

local function blacklisted(id)
    local t = state.farm_bl and state.farm_bl[id]
    if t and now() < t then return true end
    if t then state.farm_bl[id] = nil end
    return false
end

function farm.skip(id, secs, why)
    state.farm_bl = state.farm_bl or {}
    if not id or blacklisted(id) then return end
    state.farm_bl[id] = now() + (secs or 90)
    state.farm_skipped = (state.farm_skipped or 0) + 1
    local m = windower.ffxi.get_mob_by_id(id)
    h.log(('Skipping %s for a while: %s'):format(m and m.name or 'that mob', why or "can't reach it"))
    if state.farm_go and state.farm_go.id == id then state.farm_go = nil end
end

-- 'target' (fight it), 'aggro' (attacking us: fight it first), or nil (leave it) - and a word for the radar
function farm.judge(mob, me, ids, center)
    if not mob or mob.spawn_type ~= 16 or not mob.valid_target or (mob.hpp or 0) <= 0 then return nil, nil end
    local ignore = list(S.farm.ignore)
    if matches(mob.name, ignore) then return nil, 'ignored' end
    local claimed_us = mob.claim_id and mob.claim_id ~= 0 and ids[mob.claim_id]
    local claimed_other = mob.claim_id and mob.claim_id ~= 0 and not claimed_us
    if blacklisted(mob.id) then return nil, 'skipped' end
    if claimed_other and S.farm.claim ~= 'any' then return nil, 'theirs' end
    if S.farm.claim == 'party' and not claimed_us then return nil, 'unclaimed' end
    if math.abs((mob.z or 0) - (me.z or 0)) > S.farm.height then return nil, 'too high/low' end
    local d = center and dist2(mob, center) or util.dist(mob)
    local aggro = claimed_us and S.farm.aggro_first
    if d > S.farm.range and not (aggro and util.dist(mob) <= S.farm.range + 10) then return nil, 'out of range' end
    if aggro then return 'aggro', 'attacking us' end
    local mode = S.farm.mode
    if mode == 'aggro' then return nil, 'not attacking us' end
    if mode == 'any' or matches(mob.name, list(S.farm.targets)) then return 'target', 'to fight' end
    return nil, 'not on the list'
end

local function center_of(me)
    if use_route() then return nil end            -- on a route: around wherever it is
    return farm.camp() or nil
end

-- How many other enemies stand within farm.pack_range of this one (alive, not someone else's): the ones that may come
-- along when it's pulled. 0 when pack checking is off.
function farm.pack_count(mob, ids, mobs)
    if not (S.farm.packs or S.farm.pack_strict) or (tonumber(S.farm.pack_range) or 0) <= 0 then return 0 end
    local n, r = 0, tonumber(S.farm.pack_range)
    for _, o in pairs(mobs or windower.ffxi.get_mob_array() or {}) do
        if type(o) == 'table' and o.id ~= mob.id and o.spawn_type == 16 and (o.hpp or 0) > 0 and o.x and mob.x
            and not (o.claim_id and o.claim_id ~= 0 and not ids[o.claim_id])
            and math.abs((o.z or 0) - (mob.z or 0)) <= 8 and dist2(o, mob) <= r then
            n = n + 1
        end
    end
    return n
end

local function best_target(me)
    local _, ids = party()
    local center = center_of(me)
    local best, best_score
    local mobs = windower.ffxi.get_mob_array() or {}
    state.farm_packed = 0
    for _, mob in pairs(mobs) do
        local verdict = farm.judge(mob, me, ids, center)
        if verdict then
            local score = util.dist(mob) * farm.pay_factor(mob.name) - (verdict == 'aggro' and 1000 or 0)
            local n = verdict == 'target' and farm.pack_count(mob, ids, mobs) or 0
            if n > 0 and S.farm.pack_strict then
                state.farm_packed = state.farm_packed + 1     -- left for now: it has company
                score = nil
            elseif n > 0 then
                score = score + 25 * n                        -- a lone mob 25 yalms further is still better
            end
            if score and (not best or score < best_score) then best, best_score = mob, score end
        end
    end
    return best
end

------------------------------------------------------------------------
-- engaging: the way a player does it, and giving up on what it can't reach
------------------------------------------------------------------------
-- Going for a mob: how close it has got. Gives up (skip list) after 8 s without getting closer, unless it's already
-- next to it (then it's the engaging that's being tried).
local ATTACK_RANGE = 20         -- /attack from here; further away it walks first (the game won't engage from 30+)
local function progress(mob)
    local go = state.farm_go
    if not go or go.id ~= mob.id then
        go = { id = mob.id, t = now(), best = util.dist(mob), best_t = now(), tries = 0, attacks = 0 }
        state.farm_go = go
    end
    local d = util.dist(mob)
    if d < go.best - 1 or d <= 5 then go.best, go.best_t = math.min(d, go.best), now() end
    if now() - go.best_t > 8 then farm.skip(mob.id, 120, "can't get any closer") return nil end
    return go, d
end

local function walk_to(me, mob, d)
    h.run_toward(me, mob)
    state.route_moving = true
    status(('walking to %s (%d yalms)'):format(mob.name, math.floor(d + 0.5)))
end

local function engage(me, mob)
    local _, ids = party()
    local t = windower.ffxi.get_mob_by_target('t')
    if t and farm.judge(t, me, ids, center_of(me)) then
        local go, d = progress(t)
        if not go then return false end
        -- too far to engage: walk first (the old code sent /attack from 35 yalms every 3 s and never moved)
        if d > ATTACK_RANGE then walk_to(me, t, d) return false end
        if h.recently('farm:attack', 4) then return false end
        if go.attacks >= 3 then farm.skip(t.id, 120, "it won't engage") return false end
        -- an /attack that didn't take: get right next to it before the next try
        if go.attacks >= 1 and d > 5 then walk_to(me, t, d) return false end
        go.attacks = go.attacks + 1
        h.mark('farm:attack')
        h.stop_running()
        h.face(me, t)
        windower.send_command('input /attack <t>')
        h.log(('Engaging %s (%.1f yalms)'):format(t.name, d))
        state.busy_until = math.max(state.busy_until or 0, now() + 1.5)
        return true
    end
    -- /targetbnpc picks the nearest enemy: when it picked another one, walk closer to ours first
    local go, d = progress(mob)
    if not go then return false end
    if go.tries >= 2 and d > 4 then
        h.run_toward(me, mob)
        state.route_moving = true
        return false
    end
    if h.recently('farm:target', 2.5) then return false end
    h.mark('farm:target')
    go.tries = go.tries + 1
    h.stop_running()
    h.face(me, mob)
    windower.send_command('input /targetbnpc')
    state.busy_until = math.max(state.busy_until or 0, now() + 0.8)
    return true
end

-- the pull command once per mob, right after engaging while it's still away (before any abilities)
function farm.pull(player)
    if not S.modules.farm or player.status ~= 1 or (S.farm.pull_cmd or '') == '' then return false end
    local t = windower.ffxi.get_mob_by_target('t')
    if t and not state.farm_pulled[t.id] and util.dist(t) > 5 then
        state.farm_pulled[t.id] = true
        windower.send_command(S.farm.pull_cmd)
        state.busy_until = now() + 3
        return true
    end
    return false
end

-- action messages: what the game says when it can't reach / attack our mob
local GIVE_UP = { [4] = 'out of range', [5] = "can't see it", [12] = 'someone else claimed it', [78] = 'too far away',
    [154] = 'out of range', [198] = 'too far away', [217] = "can't see it", [219] = "can't see it", [328] = 'too far away',
    [446] = "can't attack it" }
function farm.on_message(actor_id, target_id, message_id)
    if not S.modules.farm or not GIVE_UP[message_id] then return end
    local p = windower.ffxi.get_player()
    if not p or actor_id ~= p.id then return end
    local t = windower.ffxi.get_mob_by_target('t')
    local id = (t and t.id) or (state.farm_go and state.farm_go.id) or target_id
    state.farm_fails = state.farm_fails or {}
    state.farm_fails[id] = (state.farm_fails[id] or 0) + 1
    if state.farm_fails[id] >= 3 or message_id == 12 then
        state.farm_fails[id] = nil
        farm.skip(id, message_id == 12 and 180 or 120, GIVE_UP[message_id])
        if p.status == 1 then windower.send_command('input /attackoff') end
    end
end

------------------------------------------------------------------------
-- mob report (round 11, farming 4/5): per kind of mob, how long a kill takes and what it pays (XP / CP per kill,
-- points per minute of fighting) - DreamBot-style numbers, so you can see which mob is worth farming; "prefer the
-- best" then picks the better-paying mob when several are near
------------------------------------------------------------------------
local function points() local st = require('vg_stats').get() or {} return st.exp or 0, st.cp or 0 end

-- every tick while engaged: note when the fight with this mob started (and the XP / CP then)
function farm.fight_tick(player)
    if not S.modules.farm then return end
    local t = windower.ffxi.get_mob_by_target('t')
    if player.status == 1 and t and state.farm_fight ~= t.id then
        local xp, cp = points()
        state.farm_fight = t.id
        state.farm_fight_info = { name = t.name, t = now(), xp = xp, cp = cp }
    end
    local p = state.farm_pending
    if p and now() >= p.at then                 -- the XP message comes just after the kill
        state.farm_pending = nil
        local xp, cp = points()
        state.farm_report = state.farm_report or {}
        local r = state.farm_report[p.name] or { k = 0, secs = 0, xp = 0, cp = 0 }
        r.k, r.secs = r.k + 1, r.secs + p.secs
        r.xp, r.cp = r.xp + math.max(0, xp - p.xp), r.cp + math.max(0, cp - p.cp)
        state.farm_report[p.name] = r
    end
end

-- a party kill (from vg_stats): if it was the mob we were fighting, wait a moment for its XP, then record it
function farm.on_kill(mob)
    local f = state.farm_fight_info
    if not f or state.farm_fight ~= mob.id then return end
    state.farm_pending = { name = f.name, secs = math.max(1, now() - f.t), xp = f.xp, cp = f.cp, at = now() + 2 }
    state.farm_fight, state.farm_fight_info = nil, nil
end

function farm.report()
    local out = {}
    for name, r in pairs(state.farm_report or {}) do
        local pts = r.xp + r.cp
        out[#out + 1] = { n = name, k = r.k, avg = math.floor(r.secs / r.k + 0.5), xp = math.floor(r.xp / r.k + 0.5),
                          cp = math.floor(r.cp / r.k + 0.5), pm = math.floor(pts * 60 / math.max(1, r.secs) + 0.5) }
    end
    table.sort(out, function(a, b) if a.pm ~= b.pm then return a.pm > b.pm end return a.n < b.n end)
    while #out > 10 do table.remove(out) end
    return out
end

-- "prefer the best": a slower-paying mob counts as further away (by how much worse it pays)
function farm.pay_factor(name)
    if not S.farm.prefer_best then return 1 end
    local rep, best = state.farm_report or {}, 0
    for _, r in pairs(rep) do if r.k >= 2 then best = math.max(best, (r.xp + r.cp) / math.max(1, r.secs)) end end
    local r = rep[name]
    if best <= 0 or not r or r.k < 2 then return 1 end
    local mine = (r.xp + r.cp) / math.max(1, r.secs)
    if mine <= 0 then return 4 end
    return math.min(4, best / mine)
end

------------------------------------------------------------------------
-- XP / CP chains (round 12, farming 5/5): the game says the chain number with the points after each kill. The time
-- allowed between kills isn't guessed: it's learned from this run - a chain that went on after N s means the window
-- is at least N s, one that broke after N s means it's under N s. "Keep the chain going" then waits only for real
-- emergencies (HP 40 %, MP 15 %) while a chain is running and there's time left.
------------------------------------------------------------------------
function farm.on_points(chain)
    local t = now()
    if state.chain_t and t - state.chain_t < 2 then        -- XP and CP messages for the same kill
        state.chain_n = math.max(state.chain_n or 0, chain)
        return
    end
    local gap = state.chain_t and (t - state.chain_t) or nil
    if gap then
        if chain >= 1 then state.chain_min = math.max(state.chain_min or 0, gap)
        elseif (state.chain_n or 0) >= 1 then state.chain_max = math.min(state.chain_max or 9999, gap) end
    end
    state.chain_n, state.chain_t = chain, t
    state.chain_best = math.max(state.chain_best or 0, chain)
end

function farm.chain_info()
    if not state.chain_t then return nil end
    return { n = state.chain_n or 0, since = math.floor(now() - state.chain_t + 0.5), best = state.chain_best or 0,
             min = state.chain_min and math.floor(state.chain_min + 0.5) or nil,
             max = state.chain_max and state.chain_max < 9999 and math.floor(state.chain_max + 0.5) or nil }
end

-- a chain is running and there's still time to keep it (10 s to spare inside what we know of the window)
function farm.chain_running()
    if not S.farm.keep_chain or not state.chain_t or (state.chain_n or 0) < 1 then return false end
    local window = state.chain_min or 30
    return now() - state.chain_t < window - 10
end

------------------------------------------------------------------------
-- the run: stats and stop conditions
------------------------------------------------------------------------
local function kills_now() return (require('vg_stats').get() or {}).kills or 0 end

------------------------------------------------------------------------
-- loot (round 9, farming 2/5): what came into the bags this run, and farming for an item ("until I have 12 of X") -
-- DreamBot / OSBot combat scripts show loot gained and stop at an item count; EasyFarm can't
------------------------------------------------------------------------
local function inv_counts()
    local out = {}
    local inv = windower.ffxi.get_items('inventory') or {}
    for _, it in ipairs(inv) do
        if type(it) == 'table' and it.id and it.id > 0 then out[it.id] = (out[it.id] or 0) + (it.count or 1) end
    end
    return out
end

local item_ids                                   -- lower-case name -> id (built once)
local function item_id(name)
    if not name or name == '' then return nil end
    if not item_ids then
        item_ids = {}
        for id, it in pairs(res.items) do
            if type(it) == 'table' and it.en then item_ids[it.en:lower()] = id end
        end
    end
    return item_ids[name:lower()]
end
farm.item_id = item_id

local function item_name(id) local it = res.items[id] return it and it.en or ('item ' .. tostring(id)) end

-- every couple of seconds while farming: anything new in the bags counts as loot
function farm.loot_tick()
    if not S.modules.farm or not state.farm_run then return end
    if state.farm_inv_t and now() - state.farm_inv_t < 2 then return end
    state.farm_inv_t = now()
    local cur = inv_counts()
    local before = state.farm_inv or cur
    state.farm_loot = state.farm_loot or {}
    for id, n in pairs(cur) do
        local gained = n - (before[id] or 0)
        if gained > 0 then state.farm_loot[id] = (state.farm_loot[id] or 0) + gained end
    end
    state.farm_inv = cur
end

-- how many of the item it's farming for are in the inventory now
function farm.item_have()
    local id = item_id(S.farm.item)
    if not id then return nil end
    return inv_counts()[id] or 0
end

function farm.loot_list()
    local out = {}
    for id, n in pairs(state.farm_loot or {}) do out[#out + 1] = { n = item_name(id), c = n } end
    table.sort(out, function(a, b) if a.c ~= b.c then return a.c > b.c end return a.n < b.n end)
    while #out > 8 do table.remove(out) end
    return out
end

-- names of what's in the inventory, for the app's item picker
function farm.inventory_names()
    local seen, out = {}, {}
    for id in pairs(inv_counts()) do
        local it = res.items[id]
        if it and it.en and not seen[it.en] then seen[it.en] = true out[#out + 1] = it.en end
    end
    table.sort(out)
    while #out > 80 do table.remove(out) end
    return out
end

function farm.start(player, me)
    state.farm_run = { t = now(), kills0 = kills_now() }
    state.farm_inv, state.farm_inv_t, state.farm_loot = inv_counts(), now(), {}
    state.farm_bl, state.farm_skipped, state.farm_go, state.farm_fails = {}, 0, nil, {}
    if me and (S.farm.area ~= 'route') and not farm.camp() then farm.set_camp(me) end
end

-- "Bring each mob back to camp": the others (who follow this farmer) wait at the camp (the team camp order, vg_camp)
function farm.share_camp(player, on)
    if not player then return end
    local camp = farm.camp()
    if on and S.farm.pull_back and S.farm.area == 'camp' and camp then
        windower.send_ipc_message(('vg_camp %s %.2f %.2f %.3f %d pull'):format(player.name, camp.x, camp.y, 0, zone()))
        h.log('The others wait at camp; I bring the mobs back')
    elseif not on or not S.farm.pull_back then
        windower.send_ipc_message(('vg_camp %s off'):format(player.name))
    end
end

function farm.run_stats()
    local r = state.farm_run
    if not r then return nil end
    local secs = math.max(1, math.floor(now() - r.t))
    local kills = math.max(0, kills_now() - r.kills0)
    local have = farm.item_have()
    return { secs = secs, kills = kills, kph = secs >= 120 and math.floor(kills * 3600 / secs + 0.5) or nil,
             every = kills > 0 and math.floor(secs / kills + 0.5) or nil, skipped = state.farm_skipped or 0,
             loot = farm.loot_list(), mobs = farm.report(), chain = farm.chain_info(),
             item = have and { n = S.farm.item, have = have, goal = S.farm.item_goal } or nil }
end

-- a reason to stop farming now, or nil
local function stop_reason(player)
    if player.status == 2 or player.status == 3 then return "KO'd" end
    local r = farm.run_stats()
    if r and S.farm.stop_kills > 0 and r.kills >= S.farm.stop_kills then return r.kills .. ' kills done' end
    local have = farm.item_have()
    if have and S.farm.item_goal > 0 and have >= S.farm.item_goal then return ('%d %s in the bags'):format(have, S.farm.item) end
    if r and S.farm.stop_mins > 0 and r.secs >= S.farm.stop_mins * 60 then return S.farm.stop_mins .. ' minutes done' end
    if S.farm.stop_full then
        local inv = windower.ffxi.get_items('inventory')
        if inv and inv.max and inv.max > 0 and (inv.count or 0) >= inv.max then return 'the inventory is full' end
    end
    return nil
end

function farm.check_stop(player)
    if not S.modules.farm or not S.enabled then return false end
    local why = stop_reason(player)
    if not why then return false end
    farm.finish(player, why)
    return true
end

-- Stop farming (a stop condition, a zone change) and do what "When done" says: stay, warp everyone home, or log
-- everyone out (the normal commands, through //vg all). Not when KO'd - it can't.
function farm.finish(player, why)
    S.modules.farm, S.enabled = false, false
    h.stop_running()
    state.farm_status = 'stopped: ' .. why
    h.log('Farming stopped: ' .. why)                 -- (the app's Alarms ring on this line)
    if S.farm.pull_back then farm.share_camp(player, false) end
    local dead = player and (player.status == 2 or player.status == 3)
    if not dead and why ~= 'changed zone' then
        if S.farm.when_done == 'warp' then
            windower.send_command('vg all off; wait 1; vg all warp')
            h.log('Done: everyone warps home')
        elseif S.farm.when_done == 'logout' then
            windower.send_command('vg all off; wait 1; vg all logout')
            h.log('Done: everyone logs out')
        end
    end
    h.save()
end

-- zoned while farming (warped, fell through a zone line, KO'd home point): the camp and route belong to the old zone
function farm.on_zone()
    if not S.modules.farm then return end
    farm.finish(windower.ffxi.get_player(), 'changed zone')
end

------------------------------------------------------------------------
-- every tick (idle): pick, wait, walk
------------------------------------------------------------------------
farm.status = status

function farm.tick(player)
    if not S.modules.farm then state.farm_status = nil return false end
    state.route_moving = false
    if player.status == 1 then return false end
    if not S.enabled then status('stopped') return false end
    if state.resting or player.status == 33 then status('resting') return false end
    if player.status ~= 0 then status('waiting') return false end
    if S.farm.mode == 'list' and #list(S.farm.targets) == 0 then status('no mobs picked yet: pick what to fight') return false end
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return false end
    local camp = (not use_route()) and farm.camp() or nil

    -- something already attacking us: always fight it, even while waiting for the party
    local mob = best_target(me)
    local _, ids = party()
    local urgent = mob and farm.judge(mob, me, ids, center_of(me)) == 'aggro'
    local wait, who, low
    if not urgent then wait, who, low = farm.party_wait(player) end
    if wait then
        if low then rest_for(player, who) end
        if camp and dist2(me, camp) > 3 then
            h.run_toward(me, camp) state.route_moving = true
            status('waiting for ' .. wait .. ' - going back to camp')
        else
            status('waiting for ' .. wait)
        end
        return false
    end
    if mob then
        state.farm_idle_since, state.farm_idle_told = nil, nil
        status(('going for %s (%d yalms)'):format(mob.name, math.floor(util.dist(mob) + 0.5)))
        return engage(me, mob)
    end
    state.farm_go = nil
    -- nothing to fight for 5 minutes: say so once (the app's Alarms ring) - the spot may be camped or the list wrong
    state.farm_idle_since = state.farm_idle_since or now()
    if not state.farm_idle_told and now() - state.farm_idle_since >= 300 then
        state.farm_idle_told = true
        h.log('Farming: nothing to fight for 5 minutes')
    end

    if camp then
        if S.farm.back_to_camp and dist2(me, camp) > 3 then
            h.run_toward(me, camp) state.route_moving = true
            status('going back to camp')
            return false
        end
        if (state.farm_packed or 0) > 0 then status(('at camp, waiting for a mob on its own (%d with others next to them)'):format(state.farm_packed)) return false end
        status(('at camp, waiting for mobs within %d yalms'):format(S.farm.range))
        return false
    end
    local pts = route()
    if #pts == 0 then status(('waiting for mobs within %d yalms'):format(S.farm.range)) return false end
    if state.wp > #pts or state.wp < 1 then state.wp = 1 end
    local wp = pts[state.wp]
    if dist2(me, wp) < 2 then
        if S.farm.loop then state.wp = state.wp % #pts + 1
        else
            if state.wp + state.wp_dir > #pts or state.wp + state.wp_dir < 1 then state.wp_dir = -state.wp_dir end
            state.wp = state.wp + state.wp_dir
        end
        wp = pts[state.wp]
    end
    status(('walking the route, looking for mobs (point %d of %d)'):format(state.wp, #pts))
    h.run_toward(me, wp)
    state.route_moving = true
    return false
end

------------------------------------------------------------------------
-- radar for the app: the camp, the route, mobs coloured by what farming thinks of them, the party
------------------------------------------------------------------------
function farm.radar()
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return nil end
    local _, ids = party()
    local center = center_of(me)
    local r = function(v) return math.floor(v * 10 + 0.5) / 10 end
    local out = { me = { x = r(me.x), y = r(me.y) }, mobs = {}, party = {}, range = S.farm.range }
    local camp = farm.camp()
    if camp then out.camp = { x = r(camp.x), y = r(camp.y) } end
    if S.farm.area == 'route' then
        local pts, step = route(), 1
        if #pts > 60 then step = math.ceil(#pts / 60) end
        out.route = {}
        for i = 1, #pts, step do out.route[#out.route + 1] = { r(pts[i].x), r(pts[i].y) } end
    end
    local t = windower.ffxi.get_mob_by_target('t')
    local mobs = {}
    for _, mob in pairs(windower.ffxi.get_mob_array() or {}) do
        if type(mob) == 'table' and mob.spawn_type == 16 and (mob.hpp or 0) > 0 and mob.x and util.dist(mob) <= 60 then
            local verdict, why = farm.judge(mob, me, ids, center)
            local pk = verdict == 'target' and farm.pack_count(mob, ids) or 0
            if pk > 0 and S.farm.pack_strict then verdict = 'pack' end
            mobs[#mobs + 1] = { d = util.dist(mob), e = { x = r(mob.x), y = r(mob.y), n = mob.name,
                s = verdict or ((why == 'skipped' or why == 'theirs' or why == 'ignored') and why or 'no'),
                t = (t and t.id == mob.id) or nil, p = pk > 0 and pk or nil } }
        end
    end
    table.sort(mobs, function(a, b) return a.d < b.d end)
    for i = 1, math.min(40, #mobs) do out.mobs[i] = mobs[i].e end
    for _, m in ipairs((party())) do
        if m.mob and m.mob.x and m.name ~= (windower.ffxi.get_player() or {}).name then
            out.party[#out.party + 1] = { n = m.name, x = r(m.mob.x), y = r(m.mob.y) }
        end
    end
    return out
end

------------------------------------------------------------------------
-- farm spots: everything about a farm saved under a name, loaded with one click
------------------------------------------------------------------------
local SPOT_FIELDS = { 'targets', 'ignore', 'claim', 'mode', 'range', 'height', 'pull_cmd', 'loop', 'aggro_first',
    'approach', 'route', 'area', 'camp', 'camp_zone', 'back_to_camp', 'wait_party', 'wait_hp', 'wait_mp', 'wait_near',
    'packs', 'pack_range', 'pack_strict', 'item', 'item_goal', 'pull_back', 'prefer_best', 'keep_chain', 'stop_mins', 'when_done' }

local function spot_keys()
    local keys = {}
    for k, v in pairs(S.farmspots or {}) do if type(v) == 'string' and v ~= '' then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) return (tonumber(a:sub(2)) or 0) < (tonumber(b:sub(2)) or 0) end)
    return keys
end

function farm.spots()
    local out = {}
    for _, k in ipairs(spot_keys()) do
        local name, zid = S.farmspots[k]:match('^([^|]*)|([^|]*)|')
        out[#out + 1] = { k = k, name = name, zone = res.zones[tonumber(zid) or 0] and res.zones[tonumber(zid)].en or '?',
                          here = tonumber(zid) == zone() }
    end
    return out
end

function farm.save_spot()
    local z = res.zones[zone()] and res.zones[zone()].en or 'somewhere'
    local first = list(S.farm.targets)[1]
    local name = z .. (first and (' - ' .. first) or '')
    local parts = { name, tostring(zone()) }
    for _, f in ipairs(SPOT_FIELDS) do parts[#parts + 1] = f .. '=' .. tostring(S.farm[f]) end
    S.farmspots = S.farmspots or {}
    local key
    for _, k in ipairs(spot_keys()) do if S.farmspots[k]:match('^([^|]*)|') == name then key = k end end
    if not key then local n = 1 while S.farmspots['s' .. n] and S.farmspots['s' .. n] ~= '' do n = n + 1 end key = 's' .. n end
    S.farmspots[key] = table.concat(parts, '|')
    h.log('Farm spot saved: ' .. name)
    return name
end

function farm.load_spot(key)
    local v = S.farmspots and S.farmspots[key]
    if not v or v == '' then return false end
    local name = v:match('^([^|]*)|')
    local i = 0
    for part in v:gmatch('[^|]+') do
        i = i + 1
        local f, val = part:match('^([%w_]+)=(.*)$')
        if i > 2 and f and S.farm[f] ~= nil then
            local cur = S.farm[f]
            if type(cur) == 'number' then S.farm[f] = tonumber(val) or cur
            elseif type(cur) == 'boolean' then S.farm[f] = (val == 'true')
            else S.farm[f] = val end
        end
    end
    state.route, state.wp = nil, 1
    h.log('Farm spot loaded: ' .. tostring(name))
    return true
end

function farm.delete_spot(key)
    if S.farmspots and S.farmspots[key] then S.farmspots[key] = '' return true end
    return false
end

function farm.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return farm
