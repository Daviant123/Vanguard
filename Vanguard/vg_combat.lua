--[[
Vanguard: fighting alongside the leader (round 5, 2026-10-15).

  Disengage with the leader   When the leader stops attacking, alts that were assisting stop too (2 s later,
                              so a quick re-target doesn't count), and pets are called back
                              (BST Heel, SMN / PUP Retreat).                  //vg set assist.disengage false
  Self-defense                A mob attacking an alt while the leader isn't fighting: melee alts fight back
                              (/attack <bt>); others tell the leader they're being attacked.
                                                                              //vg set assist.defend false
  Auto-target (round 6, after Trust's "target auto")   After a kill, if another monster is still attacking
                              someone in the party and the leader isn't fighting, melee alts take it on
                              (/attack <bt>) instead of standing around.     //vg set assist.autotarget false
  Seek (1.2.0, Silmaril audit 2.6)   A melee alt standing idle while the leader isn't fighting takes the nearest
                              mob within assist.seek_range that the party has claimed or that is attacking the party
                              (unclaimed ones only with assist.seek_unclaimed), as long as the party then fights no more
                              than assist.max_mobs mobs. Off by default.      //vg set assist.seek true
  On engage (1.2.0, audit 2.7)   assist.on_engage: a command ('input /ra <t>'), a spell or an ability name, used
                              once per new mob right after this character engages. //vg set assist.on_engage Provoke
Only normal game commands.

Who owns the target (one owner per action):
  farming (modules.farm / EasyFarm) picks its own mobs - seek never runs then;
  the leader fighting -> assist (do_assist in Vanguard.lua) follows the leader's mob - seek waits;
  otherwise self-defense (a mob on me) > auto-target (a mob on the party) > seek;
  disengage-with-the-leader leaves the mob seek picked alone while it is alive.
Who owns the first action on a new mob: when farming with a pull (farm.pull_cmd / the Pull list) the farmer's pull
wins and on_engage stays quiet; otherwise on_engage.
]]

local combat = {}
local util = require('vg_util')
local S, state, h

local function clock() return os.clock() end

-- A monster that is attacking me right now (engaged and targeting me), nearest first.
local function attacker(player)
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return nil end
    local best
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if m.spawn_type == 16 and m.status == 1 and m.hpp and m.hpp > 0 and m.valid_target ~= false
            and (m.target_index == me.index or m.claim_id == player.id) and math.sqrt(m.distance or 9999) < 15 then
            if not best or (m.distance or 0) < (best.distance or 0) then best = m end
        end
    end
    return best
end
combat.attacker = attacker

-- A monster attacking anyone in my party (engaged on a party member), nearest first.
local function party_attacker(player)
    local p = windower.ffxi.get_party() or {}
    local idx = {}
    for _, k in ipairs(require('vg_util').ALLIANCE_KEYS) do if p[k] and p[k].mob then idx[p[k].mob.index] = true end end
    local best
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if m.spawn_type == 16 and m.status == 1 and m.hpp and m.hpp > 0 and m.valid_target ~= false and idx[m.target_index]
            and math.sqrt(m.distance or 9999) < 15 then
            if not best or (m.distance or 0) < (best.distance or 0) then best = m end
        end
    end
    return best
end

------------------------------------------------------------------------
-- Seek (audit 2.6). Our own filter, built from the same checks as EasyFarm's mob filter (vg_easyfarm ef.mob_filter:
-- a live monster, in range, not too far up/down, not on the ignore list, claimed by the party/alliance or attacking it).
-- ef.mob_filter itself only works inside an EasyFarm pass (its settings are read per pass), so the checks are here.
------------------------------------------------------------------------
local function party_indexes()
    local p = windower.ffxi.get_party() or {}
    local idx = {}
    for _, k in ipairs(util.ALLIANCE_KEYS) do if p[k] and p[k].mob and p[k].mob.index then idx[p[k].mob.index] = true end end
    return idx
end

local function alive_monster(m)
    return type(m) == 'table' and m.spawn_type == 16 and m.is_npc ~= false and m.valid_target ~= false
        and (m.hpp or 0) > 0 and m.status ~= 2 and m.status ~= 3
end

-- The mobs seek may take now (a set by id), and the best one: party-fought first, nearest first. nil when none.
local function seek_pick(player)
    local a = S.assist
    local range = tonumber(a.seek_range) or 15
    local max_mobs = tonumber(a.max_mobs) or 2
    local height = tonumber(S.farm and S.farm.height) or 5
    local ignore = util.split(type(S.farm and S.farm.ignore) == 'string' and S.farm.ignore or '', ',')
    local ids, idx = util.alliance_ids(), party_indexes()
    local me = windower.ffxi.get_mob_by_target('me')
    local fought, near, free_near = 0, {}, {}
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if alive_monster(m) then
            local claim = m.claim_id or 0
            local ours = claim ~= 0 and ids[claim] == true
            local on_us = m.status == 1 and m.target_index and idx[m.target_index] and claim == 0
            local d = util.dist(m)
            if (ours or on_us) and d <= 50 then fought = fought + 1 end
            local ok = d <= range and not (me and math.abs((m.z or 0) - (me.z or 0)) > height)
            if ok then
                local name = (m.name or ''):lower()
                for _, q in ipairs(ignore) do
                    q = util.trim(q):lower()
                    if q ~= '' and name:find(q, 1, true) then ok = false break end
                end
            end
            if ok and (ours or on_us) then near[#near + 1] = m
            elseif ok and claim == 0 and a.seek_unclaimed == true then free_near[#free_near + 1] = m end
        end
    end
    -- max_mobs: joining a mob the party already fights adds nothing (allowed while the party fights max_mobs or
    -- fewer); a fresh unclaimed mob would make one more (allowed only while the party fights fewer than max_mobs).
    local pool = {}
    if fought <= max_mobs then for _, m in ipairs(near) do pool[#pool + 1] = m end end
    if #pool == 0 and fought + 1 <= max_mobs then for _, m in ipairs(free_near) do pool[#pool + 1] = m end end
    if #pool == 0 then return nil end
    local ok_ids = {}
    local best
    local skip = state.seek_skip or {}
    for _, m in ipairs(pool) do
        ok_ids[m.id] = true
        -- (a mob /targetbnpc kept missing - a nearer mob we may not take is in the way: left alone for a while)
        if not ((skip[m.id] or 0) > clock()) and (not best or (m.distance or 0) < (best.distance or 0)) then best = m end
    end
    return best, ok_ids                  -- (best nil, ok_ids set: all left alone for now, but still fair game when targeted)
end
combat.seek_pick = seek_pick

local function seek(player)
    local m, ok_ids = seek_pick(player)
    if not ok_ids then return false end
    local t = windower.ffxi.get_mob_by_target('t')
    local bt = windower.ffxi.get_mob_by_target('bt')
    local cmd
    if t and ok_ids[t.id] then m, cmd = t, 'input /attack <t>'          -- (already targeted one we may take)
    elseif bt and ok_ids[bt.id] then m, cmd = bt, 'input /attack <bt>'
    end
    if not m and not cmd then return false end
    if cmd then
        if h.recently('seek', 4) then return false end
        h.mark('seek')
        state.seek_try = nil
        windower.send_command(cmd)
        state.seek_id = m.id
        h.log(('Seek: taking on %s'):format(m.name or 'a mob'))
        state.busy_until = clock() + 1.5
        return true
    end
    -- not targeted yet: face it and pick the nearest enemy (/targetbnpc); the next pass attacks it. /targetbnpc takes
    -- the nearest one, which may be a mob we may not take: after 2 tries that gave another target, this mob is left
    -- alone for 30 s (no /targetbnpc every 1.5 s for ever, no decision passes thrown away).
    if h.recently('seek_target', 1.5) then return false end
    local tr = state.seek_try
    if tr and tr.id == m.id then tr.n = tr.n + 1 else tr = { id = m.id, n = 1 } state.seek_try = tr end
    if tr.n > 2 then
        state.seek_skip = state.seek_skip or {}
        state.seek_skip[m.id] = clock() + 30
        state.seek_try = nil
        h.log(("Seek: can't target %s (another mob is nearer) - leaving it for now"):format(m.name or 'the mob'))
        return false
    end
    h.mark('seek_target')
    local me = windower.ffxi.get_mob_by_target('me')
    if me and h.face then h.face(me, m) end
    windower.send_command('input /targetbnpc')
    return true
end

-- The mob seek took is still being fought by me: disengage-with-the-leader leaves it alone.
local function seeking_now(player)
    if not state.seek_id then return false end
    if player.status ~= 1 then state.seek_id = nil return false end
    local m = windower.ffxi.get_mob_by_id(state.seek_id)
    if not alive_monster(m) then state.seek_id = nil return false end
    return true
end

local PET_RECALL = { BST = 'Heel', SMN = 'Retreat', PUP = 'Retreat' }

-- Returns true when it sent a command this tick.
function combat.tick(player)
    if S.leader == '' or not S.modules.assist then return false end
    local l = h.leader_mob(player)
    -- (fighting: engaged - or, with assist.on_claim, pulling / casting on a mob the party has claimed)
    local leader_fighting = l and (l.status == 1 or (h.leader_target and h.leader_target(player) ~= nil))

    -- Self-defense: something is hitting me and the leader isn't fighting.
    if S.assist.defend and not leader_fighting then
        local m = attacker(player)
        if m then
            state.defending = m.id
            if player.status == 0 then
                if S.assist.approach then
                    if h.recently('defend', 4) then return false end
                    h.mark('defend')
                    windower.send_command('input /attack <bt>')
                    h.log('Defending myself against ' .. m.name)
                    state.busy_until = clock() + 1.5
                    return true
                elseif not h.recently('defend_alert', 30) then
                    h.mark('defend_alert')
                    windower.send_ipc_message(('vg_alert %s %s|attacked by %s'):format(S.leader, player.name, m.name))
                end
            end
            return false
        end
        state.defending = nil
        -- Auto-target: someone else in the party is being attacked.
        if S.assist.autotarget and S.assist.approach and player.status == 0 then
            local m = party_attacker(player)
            if m and not h.recently('autotarget', 4) then
                h.mark('autotarget')
                windower.send_command('input /attack <bt>')
                h.log('Next: ' .. m.name .. ' is attacking the party')
                state.busy_until = clock() + 1.5
                state.defending = m.id
                return true
            end
        end
    end

    -- Seek (audit 2.6): last in line - farming, the leader's fight, self-defense and auto-target all come first.
    if S.assist.seek == true and S.assist.approach and player.status == 0 and not leader_fighting and not S.modules.farm
        and not state.hold and not state.retreat and not state.defending then
        if seek(player) then return true end
    end

    -- Disengage with the leader (not while farming on my own, defending myself, or fighting the mob seek took).
    -- (only when the leader is standing idle: if the leader is KO'd, keep fighting)
    if S.assist.disengage and player.status == 1 and l and l.status == 0 and not leader_fighting and not S.modules.farm and not state.defending
        and not seeking_now(player) then
        state.leader_idle_since = state.leader_idle_since or clock()
        if clock() - state.leader_idle_since >= 2 and not h.recently('disengage', 4) then
            h.mark('disengage')
            local cmd = 'input /attackoff'
            local recall = PET_RECALL[player.main_job]
            if recall and windower.ffxi.get_mob_by_target('pet') then cmd = cmd .. ('; wait 1; input /pet "%s" <me>'):format(recall) end
            windower.send_command(cmd)
            h.log(S.leader .. ' stopped fighting: disengaging')
            state.busy_until = clock() + 1.5
            return true
        end
    else
        state.leader_idle_since = nil
    end
    return false
end

------------------------------------------------------------------------
-- On engage (audit 2.7): "when I engage a new mob, use X once" for any role (the farm's "Pull with" for everyone).
------------------------------------------------------------------------
local ON_ENGAGE_GIVE_UP = 6          -- seconds: not ready (recast, MP) by then -> skip it for this mob
-- The command for assist.on_engage now: a string to send, false (not ready yet), or nil (unknown / not usable).
-- A typed command whose quotes were lost on the way (Windower's command line takes quotes off //vg set ... arguments):
-- "input /ja Light Arts <me>" -> 'input /ja "Light Arts" <me>', so a name of two or more words still works.
local function requote(c)
    local pre, name, tgt = c:match('^(input%s+/%a+%s+)([^"<>]-%s[^"<>]-)%s+(<%a+>)%s*$')
    if pre and not name:find('"') then return ('%s"%s" %s'):format(pre, util.trim(name), tgt) end
    return c
end
combat.requote = requote

local function engage_command(c, player)
    local low = c:lower()
    if low:match('^input ') then return requote(c) end
    if c:sub(1, 1) == '/' then return requote('input ' .. c) end
    if low == 'ra' or low == 'ranged' or low == 'ranged attack' then return 'input /ra <t>' end
    local sp = util.spell(c)
    if sp then
        local tgt = util.targets(sp, 'Enemy') and '<t>' or '<me>'
        if h.try_cast and h.try_cast(sp.en, tgt, 'on engage', player) then return true end
        return false
    end
    local ja = util.ability(c)
    if ja then
        if not util.ability_known(ja) then return nil end
        if not util.ability_ready(ja) then return false end
        return ('input /ja "%s" %s'):format(ja.en, util.targets(ja, 'Enemy') and '<t>' or '<me>')
    end
    return nil
end

function combat.on_engage(player)
    local c = S.assist.on_engage
    c = type(c) == 'string' and util.trim(c) or ''
    if c == '' or player.status ~= 1 or state.hold or state.retreat then return false end
    -- farming with a pull: the farmer's pull is the first action on its mobs (farm.pull_cmd still wins)
    if S.modules.farm and h.farm_has_pull and h.farm_has_pull() then return false end
    local t = windower.ffxi.get_mob_by_target('t')
    if not t or not alive_monster(t) then return false end
    local seen = state.on_engage
    if seen and seen.id == t.id and seen.done then return false end
    if not seen or seen.id ~= t.id then seen = { id = t.id, t = clock() } state.on_engage = seen end
    if clock() - seen.t > ON_ENGAGE_GIVE_UP then seen.done = true return false end
    local cmd = engage_command(c, player)
    if cmd == nil then
        seen.done = true
        if not h.recently('on_engage_bad', 60) then
            h.mark('on_engage_bad')
            h.log(("On engage: '%s' isn't a command, spell or ability this job can use"):format(c))
        end
        return false
    end
    if cmd == false then return false end
    seen.done = true
    if cmd ~= true then windower.send_command(cmd) end           -- (true: try_cast already cast it)
    h.log(('On engage: %s -> %s'):format(c, t.name or 'the mob'))
    state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
    return true
end

function combat.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return combat
