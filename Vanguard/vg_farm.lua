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
local function rest_for(player, who, attacked)
    if who == player.name then
        if not attacked and not state.resting and player.status == 0 and not h.recently('farm:rest', 8) then
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
    state.resting, state.farm_rest_called = true, true
    h.mark('farm:restcalled')
    h.log('Resting: the farmer waits for me')
end

-- the character the farmer asked to rest gets up when it's full again - even with its own resting switched off (found
-- by the team simulator: it rested to 100 % and never stood up, so the farmer waited forever)
function farm.rest_called_check(player)
    if not state.farm_rest_called or player.status ~= 33 then
        -- (sitting down takes a moment after /heal on: only forget it once it has had time to sit)
        if player.status ~= 33 and not h.recently('farm:restcalled', 5) then state.farm_rest_called = nil end
        return false
    end
    local v = player.vitals or {}
    local full = (v.hpp or 100) >= 95 and ((v.max_mp or 0) == 0 or (v.mpp or 100) >= 95)
    if not full then return false end
    h.mark('farm:getup2')
    windower.send_command('input /heal off')
    state.resting, state.farm_rest_called = false, nil
    h.log('Rested: ready for the next pull')
    return true
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
    if matches(mob.name, list(S.farm.strong)) and not (mob.claim_id and mob.claim_id ~= 0 and ids[mob.claim_id]) then
        return nil, 'too strong'
    end
    local grade = S.farm.check and (state.farm_checks or {})[mob.name]
    if grade and not (mob.claim_id and mob.claim_id ~= 0 and ids[mob.claim_id]) then
        if S.farm.skip_weak and grade == 'weak' then return nil, 'too weak' end
        if S.farm.skip_tough and (grade == 'itough' or grade == 'nm') then return nil, 'too strong' end
    end
    local claimed_us = mob.claim_id and mob.claim_id ~= 0 and ids[mob.claim_id]
    local claimed_other = mob.claim_id and mob.claim_id ~= 0 and not claimed_us
    if blacklisted(mob.id) then return nil, 'skipped' end
    if claimed_other and S.farm.claim ~= 'any' then return nil, 'theirs' end
    if S.farm.claim == 'party' and not claimed_us then return nil, 'unclaimed' end
    if math.abs((mob.z or 0) - (me.z or 0)) > S.farm.height then return nil, 'too high/low' end
    -- courtesy (upgrade 14): an unclaimed mob with another player (not in our party) right next to it is probably
    -- theirs in a second - leave it rather than race them for the claim
    if S.farm.polite and not claimed_us and (not mob.claim_id or mob.claim_id == 0) and farm.player_near(mob, ids) then
        return nil, 'theirs'
    end
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

-- another player (not in our party, not a trust / NPC) within 6 yalms of this mob?
function farm.player_near(mob, ids)
    if not mob.x then return false end
    for _, o in pairs(windower.ffxi.get_mob_array() or {}) do
        if util.is_player(o) and o.x and not ids[o.id]
            and (o.hpp or 0) > 0 and dist2(o, mob) <= 6 then
            return true
        end
    end
    return false
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

-- is this index another party member (not the farmer)?
function farm.on_party_member(index)
    local p = windower.ffxi.get_party() or {}
    local me = windower.ffxi.get_player()
    for _, k in ipairs({ 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        if p[k] and p[k].mob and p[k].mob.index == index and (not me or p[k].mob.id ~= me.id) then return true end
    end
    return false
end

local function best_target(me)
    local _, ids = party()
    local center = center_of(me)
    local best, best_score
    local mobs = windower.ffxi.get_mob_array() or {}
    state.farm_packed = 0
    local seen, theirs = 0, 0                         -- how busy the spot is (mobs on the list someone else has)
    for _, mob in pairs(mobs) do
        local verdict, why = farm.judge(mob, me, ids, center)
        if type(mob) == 'table' and mob.spawn_type == 16 and (mob.hpp or 0) > 0 and (S.farm.mode ~= 'list' or matches(mob.name, list(S.farm.targets))) then
            if verdict or why == 'theirs' then seen = seen + 1 end
            if why == 'theirs' then theirs = theirs + 1 end
        end
        if verdict then
            local score = util.dist(mob) * farm.pay_factor(mob.name) - (verdict == 'aggro' and 1000 or 0)
            -- protect the party (upgrade 10): a mob hitting another party member (the healer) comes before one on us
            if verdict == 'aggro' and mob.target_index and mob.target_index ~= 0 and farm.on_party_member(mob.target_index) then
                score = score - 1000
            end
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
    state.farm_busy = { theirs = theirs, seen = seen }
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
    -- fight what's targeted only if it's the mob we chose (or one as good: on the list, not attacking someone else);
    -- otherwise /targetbnpc picked a nearer one - walk closer to ours (found by the team simulator: it took the goblin
    -- on itself instead of the one hitting the healer)
    local tv = t and farm.judge(t, me, ids, center_of(me))
    local chosen_v = farm.judge(mob, me, ids, center_of(me))
    local tries = (state.farm_go and state.farm_go.id == mob.id) and state.farm_go.tries or 0
    if tv and t.id ~= mob.id and tries < 4 and (chosen_v == 'aggro' and tv ~= 'aggro' or
        (mob.target_index and farm.on_party_member(mob.target_index) and not (t.target_index and farm.on_party_member(t.target_index)))) then
        tv = nil
    end
    if t and tv then
        local go, d = progress(t)
        if not go then return false end
        -- /check each new kind once (upgrade 11), before engaging: the answer decides "too weak" / "too tough"
        if S.farm.check and not (state.farm_checks or {})[t.name] and d <= 25 then
            if state.farm_checking == t.name and h.recently('farm:check', 3) then return false end
            if state.farm_checking == t.name then                -- no answer: don't ask again
                state.farm_checks = state.farm_checks or {}
                state.farm_checks[t.name] = 'unknown'
            else
                state.farm_checking = t.name
                h.mark('farm:check')
                windower.send_command('input /check <t>')
                status(('checking %s'):format(t.name))
                return true
            end
        end
        -- claim from range (upgrade 7): with a pull set, use it as soon as the mob is within that pull's reach - before
        -- walking up or engaging - so it's ours sooner (and comes to us)
        local pr = farm.pull_range()
        local mine = t.claim_id and t.claim_id ~= 0 and ids[t.claim_id]
        if pr and not mine and not state.farm_pulled[t.id] then
            if d > pr then walk_to(me, t, d) return false end
            state.farm_pulled[t.id] = true
            h.stop_running()
            h.face(me, t)
            windower.send_command(S.farm.pull_cmd)
            status(('pulling %s (%d yalms)'):format(t.name, math.floor(d + 0.5)))
            state.busy_until = math.max(state.busy_until or 0, now() + 2)
            return true
        end
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

-- how far the pull command reaches (a ranged attack about 24 yalms, a spell 20, an ability like Provoke 16)
function farm.pull_range()
    local c = S.farm.pull_cmd or ''
    if c == '' then return nil end
    if c:find('/ra ', 1, true) then return 23 end
    if c:find('/ma ', 1, true) then return 19 end
    if c:find('/ja ', 1, true) then return 15 end
    return nil
end

-- the /check answer, read from the chat line (the English phrases are fixed): too weak / easy prey / decent challenge /
-- even match / tough / very tough / incredibly tough; "impossible to gauge" (notorious monsters)
local GRADES = { { 'too weak', 'weak' }, { 'easy prey', 'easy' }, { 'decent challenge', 'decent' }, { 'even match', 'even' },
    { 'incredibly tough', 'itough' }, { 'very tough', 'vtough' }, { 'tough', 'tough' }, { 'impossible to gauge', 'nm' } }
function farm.on_text(text)
    local name = state.farm_checking
    if not name or not text then return end
    local low = text:lower()
    if not low:find(name:lower(), 1, true) then return end
    for _, g in ipairs(GRADES) do
        if low:find(g[1], 1, true) then
            state.farm_checks = state.farm_checks or {}
            state.farm_checks[name] = g[2]
            state.farm_checking = nil
            return
        end
    end
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
        state.farm_fight_info = { name = t.name, t = now(), xp = xp, cp = cp, low = 100, hpp = t.hpp, hurt_t = now(), id = t.id }
    end
    -- emergency (upgrade 16): HP under farm.emergency_hp in a fight -> the chosen item or ability (once per 20 s)
    if player.status == 1 and (S.farm.emergency or '') ~= '' and S.farm.emergency_hp > 0
        and ((player.vitals or {}).hpp or 100) < S.farm.emergency_hp and not h.recently('farm:emergency', 20) then
        h.mark('farm:emergency')
        windower.send_command(S.farm.emergency)
        h.log(('Emergency at %d%% HP: %s'):format((player.vitals or {}).hpp or 0, S.farm.emergency:match('"(.-)"') or S.farm.emergency))
        state.busy_until = now() + 2
    end
    local f = state.farm_fight_info
    -- stuck in a fight (upgrade 3): engaged, but its HP hasn't moved for 25 s and it's out of reach - let go of it;
    -- and one that someone else claimed while we were on it
    if f and player.status == 1 and t and t.id == f.id then
        if (t.hpp or 100) < (f.hpp or 100) then f.hpp, f.hurt_t = t.hpp, now() end
        local _, ids = party()
        local theirs = t.claim_id and t.claim_id ~= 0 and not ids[t.claim_id]
        if theirs and S.farm.claim ~= 'any' then
            windower.send_command('input /attackoff')
            farm.skip(t.id, 180, 'someone else claimed it')
            state.farm_fight, state.farm_fight_info = nil, nil
            return
        elseif now() - f.hurt_t > 25 and util.dist(t) > 6 then
            windower.send_command('input /attackoff')
            farm.skip(t.id, 120, 'no damage in 25 s and out of reach')
            state.farm_fight, state.farm_fight_info = nil, nil
            return
        end
    end
    if f and player.status == 1 then
        f.low = math.min(f.low or 100, (player.vitals or {}).hpp or 100)
        if now() - f.t > 180 and not f.long then f.long = true farm.strong_strike(f.name, 'a fight took over 3 minutes') end
    end
    if f and (player.status == 2 or player.status == 3) and not f.ko then
        f.ko = true farm.strong_strike(f.name, "it KO'd me", true)
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
    if (f.low or 100) < 25 then farm.strong_strike(f.name, ('it took me down to %d%% HP'):format(f.low)) end
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

-- Too strong (upgrade 2): a kind of mob that took the farmer under 25 % HP or needed over 3 minutes - twice - (or KO'd
-- it once) is set aside on the "too strong" list (not Leave alone: the app shows it with "fight them again").
function farm.strong_strike(name, why, now_)
    if not S.farm.skip_strong or not name then return end
    state.farm_strikes = state.farm_strikes or {}
    state.farm_strikes[name] = (state.farm_strikes[name] or 0) + 1
    if not now_ and state.farm_strikes[name] < 2 then return end
    for _, n in ipairs(list(S.farm.strong)) do if n:lower() == name:lower() then return end end
    local l = list(S.farm.strong)
    l[#l + 1] = name
    S.farm.strong = table.concat(l, ',')
    h.log(('Leaving %s alone from now on: too strong (%s)'):format(name, why))
    h.save()
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

-- kills over time (upgrade 5): a timestamp per kill this run, shown as kills per 5 minutes over the last hour
function farm.kill_watch()
    local r = state.farm_run
    if not r then return end
    local k = kills_now() - r.kills0
    r.seen = r.seen or 0
    while r.seen < k do r.seen = r.seen + 1 r.times = r.times or {} r.times[#r.times + 1] = now() end
end

function farm.spark()
    local r = state.farm_run
    if not r then return nil end
    local out = {}
    for i = 1, 12 do out[i] = 0 end
    local t = now()
    for _, kt in ipairs(r.times or {}) do
        local b = 12 - math.floor((t - kt) / 300)
        if b >= 1 and b <= 12 then out[b] = out[b] + 1 end
    end
    return out
end

-- spot rotation (upgrade 5, MMOMinion's grind markers): nothing to fight here for 3 minutes - load the next saved farm
-- spot in this zone and walk to its camp
function farm.rotate()
    if not S.farm.rotate then return false end
    local here = {}
    for _, sp in ipairs(farm.spots()) do if sp.here then here[#here + 1] = sp.k end end
    if #here < 2 then return false end
    local cur = 0
    for i, k in ipairs(here) do if k == state.farm_spot then cur = i end end
    local nxt = here[cur % #here + 1]
    if farm.load_spot(nxt) then
        state.farm_spot = nxt
        state.farm_idle_since, state.farm_idle_told = now(), nil
        h.log('This spot ran dry: moving on to ' .. (S.farmspots[nxt]:match('^([^|]*)|') or 'the next spot'))
        h.save()
        return true
    end
    return false
end

-- free inventory slots (for the dashboard and the checklist)
function farm.inv_free()
    local inv = windower.ffxi.get_items('inventory')
    if not inv or not inv.max or inv.max <= 0 then return nil end
    return math.max(0, inv.max - (inv.count or 0))
end

-- every couple of seconds while farming: anything new in the bags counts as loot
function farm.loot_tick()
    if not S.modules.farm or not state.farm_run then return end
    if state.farm_inv_t and now() - state.farm_inv_t < 2 then return end
    state.farm_inv_t = now()
    local cur = inv_counts()
    local before = state.farm_inv or cur
    state.farm_loot = state.farm_loot or {}
    local watched = {}
    for _, w in ipairs(list(S.farm.watch)) do watched[w:lower()] = true end
    for id, n in pairs(cur) do
        local gained = n - (before[id] or 0)
        if gained > 0 then
            state.farm_loot[id] = (state.farm_loot[id] or 0) + gained
            -- rare drop alert (upgrade 19): an item on the watch list - say it (the app's Alarms ring on "Farming: ")
            local nm = item_name(id)
            if watched[nm:lower()] then h.log(('Farming: got %s!'):format(nm)) end
        end
    end
    state.farm_inv = cur
end

-- how many of the item it's farming for are in the inventory now
function farm.item_have()
    local id = item_id(S.farm.item)
    if not id then return nil end
    return inv_counts()[id] or 0
end

-- loot value (upgrade 17, the gil / hour DreamBot-style clients show): auction-house medians from Steward's price list
-- (addons/Steward/data/prices.lua, read only, if Steward is there); items it hasn't priced aren't counted
local prices, prices_t
function farm.set_prices(t) prices, prices_t = t, now() end
local function price_list()
    if prices and prices_t and now() - prices_t < 600 then return prices end
    local ok, t = pcall(function()
        local f = io.open(windower.addon_path .. '../Steward/data/prices.lua', 'r')
        if not f then return nil end
        local src = f:read('*a') f:close()
        local chunk = (loadstring or load)(src)
        return chunk and chunk() or nil
    end)
    prices, prices_t = (ok and type(t) == 'table') and t or (prices or {}), now()
    return prices
end

function farm.loot_value()
    local pl = price_list()
    local total, priced, unpriced = 0, 0, 0
    for id, n in pairs(state.farm_loot or {}) do
        local p = pl[id]
        if type(p) == 'table' and tonumber(p.m) then total, priced = total + n * tonumber(p.m), priced + n
        else unpriced = unpriced + n end
    end
    if priced == 0 then return nil end
    return { gil = total, priced = priced, unpriced = unpriced }
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
    local xp, cp = points()
    state.farm_run = { t = now(), kills0 = kills_now(), xp0 = xp, cp0 = cp }
    state.farm_inv, state.farm_inv_t, state.farm_loot = inv_counts(), now(), {}
    state.farm_bl, state.farm_skipped, state.farm_go, state.farm_fails = {}, 0, nil, {}
    if me and (S.farm.area ~= 'route') and not farm.camp() then farm.set_camp(me) end
    farm.treasure(true)
end

-- Treasure Hunter (upgrade 4): GearSwap's TreasureMode (Mote / Selindrile files: Tag = TH gear on each new mob) on
-- while farming, back to None when it stops. A normal GearSwap command; files without TreasureMode just ignore it.
function farm.treasure(on)
    if not S.farm.th then return end
    windower.send_command('gs c set TreasureMode ' .. (on and 'Tag' or 'None'))
    if on then h.log('Treasure Hunter: tagging each mob (GearSwap TreasureMode Tag)') end
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

-- pause / resume (upgrade 12): stop for a moment without ending the run; paused time isn't counted
function farm.pause(on)
    local r = state.farm_run
    if on then
        S.enabled = false
        if r and not r.paused then r.paused = now() end
        h.stop_running()
        state.farm_status = 'paused'
    else
        if r and r.paused then r.t = r.t + (now() - r.paused) r.paused = nil end
        S.enabled = true
        state.farm_status = 'resuming'
    end
end

function farm.run_stats()
    local r = state.farm_run
    if not r then return nil end
    local secs = math.max(1, math.floor((r.paused or now()) - r.t))
    local kills = math.max(0, kills_now() - r.kills0)
    local have = farm.item_have()
    return { secs = secs, kills = kills, kph = secs >= 120 and math.floor(kills * 3600 / secs + 0.5) or nil,
             every = kills > 0 and math.floor(secs / kills + 0.5) or nil, skipped = state.farm_skipped or 0,
             loot = farm.loot_list(), mobs = farm.report(), chain = farm.chain_info(), free = farm.inv_free(),
             spark = farm.spark(), busy = state.farm_busy, checks = state.farm_checks, value = farm.loot_value(),
             item = have and { n = S.farm.item, have = have, goal = S.farm.item_goal } or nil, paused = r.paused and true or nil }
end

-- a reason to stop farming now, or nil
local function stop_reason(player)
    if player.status == 2 or player.status == 3 then return "KO'd" end
    local r = farm.run_stats()
    if r and S.farm.stop_kills > 0 and r.kills >= S.farm.stop_kills then return r.kills .. ' kills done' end
    local have = farm.item_have()
    if have and S.farm.item_goal > 0 and have >= S.farm.item_goal then return ('%d %s in the bags'):format(have, S.farm.item) end
    if r and S.farm.stop_mins > 0 and r.secs >= S.farm.stop_mins * 60 then return S.farm.stop_mins .. ' minutes done' end
    local ok, tr = pcall(require, 'vg_trials')
    if ok and tr.assist_done and tr.assist_done() then S.trial_assist = '' return 'Magian trial done' end
    if S.farm.stop_full then
        local inv = windower.ffxi.get_items('inventory')
        if inv and inv.max and inv.max > 0 and (inv.count or 0) >= inv.max then return 'the inventory is full' end
    end
    return nil
end

function farm.check_stop(player)
    if not S.modules.farm or not S.enabled then return false end
    -- once a second is plenty (it looks through the inventory); a KO is checked every time
    if not (player.status == 2 or player.status == 3) then
        if state.farm_stop_t and now() - state.farm_stop_t < 1 then return false end
        state.farm_stop_t = now()
    end
    local why = stop_reason(player)
    if not why then return false end
    farm.finish(player, why)
    return true
end

-- Past runs (upgrade 2): when a run ends, its summary goes to the app, which keeps a history (DreamBot-style logs)
function farm.send_run(player, why)
    local r = farm.run_stats()
    if not r then return end
    local xp, cp = points()
    local z = res.zones[zone()] and res.zones[zone()].en or '?'
    local top = {}
    for i, l in ipairs(r.loot or {}) do if i <= 3 then top[#top + 1] = l.c .. ' ' .. l.n end end
    local mins = math.floor(r.secs / 60)
    h.log(('Run over (%s): %d min, %d kills%s, %d XP, %d CP%s'):format(why or 'stopped', mins, r.kills,
        r.kph and (' (' .. r.kph .. ' an hour)') or '', math.max(0, xp - (state.farm_run.xp0 or xp)), math.max(0, cp - (state.farm_run.cp0 or cp)),
        #top > 0 and (', loot: ' .. table.concat(top, ', ')) or ''))
    if h.send then pcall(h.send, { type = 'farmrun', name = player and player.name or '?', zone = z, secs = r.secs, kills = r.kills,
        xp = math.max(0, xp - (state.farm_run.xp0 or xp)), cp = math.max(0, cp - (state.farm_run.cp0 or cp)),
        loot = table.concat(top, ', '), why = why or 'stopped', mobs = list(S.farm.targets)[1] or S.farm.mode }) end
    state.farm_run = nil
end

-- Stop farming (a stop condition, a zone change) and do what "When done" says: stay, warp everyone home, or log
-- everyone out (the normal commands, through //vg all). Not when KO'd - it can't.
function farm.finish(player, why)
    farm.send_run(player, why)
    farm.treasure(false)
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
    if not S.enabled then status(state.farm_run and state.farm_run.paused and 'paused' or 'stopped') return false end
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
    if now() - state.farm_idle_since >= 180 and farm.rotate() then return false end
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
        if farm.rest_idle(player) then return true end
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
-- rest while there's nothing to fight (upgrade 8): waiting at camp with HP or MP under 90 % -> /heal; get up as soon
-- as there's a mob to fight (farm.rest_check, called while resting)
------------------------------------------------------------------------
function farm.rest_idle(player)
    if not S.farm.rest_idle or player.status ~= 0 or state.resting or h.recently('farm:idlerest', 10) then return false end
    local v = player.vitals or {}
    local low = (v.hpp or 100) < 90 or ((v.max_mp or 0) > 0 and (v.mpp or 100) < 90)
    if not low then return false end
    h.mark('farm:idlerest')
    h.mark('farm:rest')
    windower.send_command('input /heal on')
    state.resting, state.farm_rest_idle = true, true
    status('resting while there is nothing to fight')
    return true
end

function farm.rest_check(player)
    if not S.modules.farm or not state.farm_rest_idle or player.status ~= 33 then return false end
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return false end
    local mob = best_target(me)
    if not mob then status('resting while there is nothing to fight') return false end
    if h.recently('farm:getup', 3) then return false end
    h.mark('farm:getup')
    windower.send_command('input /heal off')
    state.resting, state.farm_rest_idle = false, false
    status(('getting up: %s to fight'):format(mob.name))
    return true
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
                s = verdict or ((why == 'skipped' or why == 'theirs' or why == 'ignored') and why or why == 'too strong' and 'strong' or 'no'),
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
    'packs', 'pack_range', 'pack_strict', 'item', 'item_goal', 'pull_back', 'prefer_best', 'keep_chain', 'stop_mins', 'when_done', 'skip_strong', 'strong', 'th', 'check', 'skip_weak', 'skip_tough' }

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
                          here = tonumber(zid) == zone(),
                          -- the whole spot, for "copy to another character" (';' travels as '~': it ends a game command)
                          raw = S.farmspots[k]:gsub(';', '~') }
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

-- a spot copied from another character (upgrade 18): "name|zone|field=value|..." with '~' for ';'
function farm.import_spot(raw)
    raw = (raw or ''):gsub('~', ';')
    local name, zid = raw:match('^([^|]+)|(%d+)|')
    if not name then return nil end
    S.farmspots = S.farmspots or {}
    local key
    for _, k in ipairs(spot_keys()) do if S.farmspots[k]:match('^([^|]*)|') == name then key = k end end
    if not key then local n = 1 while S.farmspots['s' .. n] and S.farmspots['s' .. n] ~= '' do n = n + 1 end key = 's' .. n end
    S.farmspots[key] = raw
    h.log('Farm spot received: ' .. name)
    return key
end

function farm.delete_spot(key)
    if S.farmspots and S.farmspots[key] then S.farmspots[key] = '' return true end
    return false
end

------------------------------------------------------------------------
-- one-click presets (upgrade 3): sensible settings for the usual kinds of farming
------------------------------------------------------------------------
farm.PRESETS = {
    -- an XP / CP party: pull to camp, keep the healer topped up, keep chains, prefer the best payer, avoid packs
    party = { mode = 'list', area = 'camp', pull_back = true, back_to_camp = true, wait_party = true, wait_hp = 70,
              wait_mp = 40, keep_chain = true, prefer_best = true, packs = true, pack_strict = false, skip_strong = true,
              check = true, skip_weak = true, skip_tough = true },
    -- an item: fast, little waiting, stop when the bags fill
    items = { mode = 'list', pull_back = false, back_to_camp = false, wait_party = true, wait_hp = 50, wait_mp = 20,
              keep_chain = false, prefer_best = false, packs = true, pack_strict = false, stop_full = true, skip_strong = true,
              th = true },
    -- careful, on its own: only lone mobs, rest early, set aside anything too strong
    safe = { mode = 'list', area = 'camp', pull_back = false, back_to_camp = true, wait_party = true, wait_hp = 85,
             wait_mp = 50, aggro_first = true, packs = true, pack_strict = true, skip_strong = true, keep_chain = false,
             check = true, skip_tough = true },
    -- clear everything around the camp
    clear = { mode = 'any', area = 'camp', pull_back = false, back_to_camp = true, wait_party = true, wait_hp = 60,
              wait_mp = 30, packs = false, pack_strict = false, skip_strong = true, aggro_first = true },
}
function farm.preset(name)
    local p = farm.PRESETS[name]
    if not p then return false end
    for k, v in pairs(p) do if S.farm[k] ~= nil then S.farm[k] = v end end
    S.farm.preset = name
    return true
end

function farm.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return farm
