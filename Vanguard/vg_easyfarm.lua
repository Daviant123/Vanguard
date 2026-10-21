--[[
Vanguard: EasyFarm's farming engine, rebuilt (his request 2026-10-21: "i want the farming part to run exactly as if i
was using easy farm. from top to bottom i basically want the clone here. the only exception i do not want to use the
.dll or api that it uses").

A line-by-line port of EasyFarm's state machine (github.com/EasyFarm/EasyFarm, EasyFarm/States/*.cs, read 2026-10-21):
the same states with the same priorities, checked in the same order every 250 ms, each one's Check / Enter / Run / Exit;
the same mob filter (UnitFilters.MobFilter), the same action filters (ActionFilters.BuffingFilter / TargetedFilter), the
same Executor rules (move into the action's distance, face, target, use; global cooldown after each action; usages and
recast per action, usages reset at End), the same rest rules (RestState) and route walking (Route.GetNextPosition).

Where EasyFarm reads or writes game memory through EliteAPI, this uses Windower's own functions and normal commands:
  memory target (Target.SetNPCTarget)  ->  /ta <bt> for the party's mob, else /targetbnpc and walking closer until the
                                           wanted mob is the nearest
  Navigator (GotoNPC / FaceHeading)    ->  windower.ffxi.run / windower.ffxi.turn (the same as Vanguard's walking)
  cast monitoring (CastPercentEx)      ->  Vanguard's own casting wait (busy until the cast time is over)
  chat log / key presses               ->  not used (Home Point On Death, Tab Targeting, Avoid Objects are left out)
No packets are sent.

Priorities (higher first, EasyFarm's numbers): StartEngine (max), Dead 7, Zone 7, SetTarget 7, SetFighting 7,
SummonTrusts 6, Follow 5, Start 5, Pull 4, Battle 3, End 3, Rest 2, Weaponskill 2, Healing 2, Travel 1, Approach 0.
Every state whose Check is true runs, in that order, each pass.
]]
local util = require('vg_util')
local res = require('resources')

local ef = {}
local S, state, h

local function clock() return os.clock() end

------------------------------------------------------------------------
-- Settings, with EasyFarm's defaults (UserSettings/Config.cs, Constants.cs)
------------------------------------------------------------------------
local function num(v, d) v = tonumber(v) return v == nil and d or v end
local function cfg()
    local f = S.farm
    return {
        detect = num(f.detect, 0) > 0 and num(f.detect, 17) or 17,      -- DetectionDistance 17
        wander = num(f.range, 17),                                      -- WanderDistance (only used with a route)
        height = num(f.height, 5),                                      -- HeightThreshold 5
        melee = num(S.assist and S.assist.melee_range, 3),              -- MeleeDistance 3
        gcd = num(f.gcd, 1000) / 1000,                                  -- GlobalCooldown 1000 ms
        approach = f.approach ~= false, engage = f.engage ~= false,     -- IsApproachEnabled, IsEngageEnabled
        aggro = f.aggro_first ~= false, party = f.f_party ~= false,     -- AggroFilter, PartyFilter
        unclaimed = f.f_unclaimed ~= false, claimed = f.f_claimed == true,
        trust_size = num(S.trusts and S.trusts.party_size, 5),         -- TrustPartySize 5
        rest_hp = f.rest_hp == true, hp_low = num(f.rest_hp_low, 50), hp_high = num(f.rest_hp_high, 100),
        rest_mp = f.rest_mp == true, mp_low = num(f.rest_mp_low, 50), mp_high = num(f.rest_mp_high, 100),
        follow = tostring(f.follow or ''), follow_dist = num(f.follow_dist, 5),
        targets = util.split(f.targets or '', ','), ignored = util.split(f.ignore or '', ','),
    }
end
local C          -- this pass's settings

------------------------------------------------------------------------
-- The game, through Windower (EasyFarm's IUnit / Player)
------------------------------------------------------------------------
local BUFF = { poison = 3, sleep = 2, sleep2 = 19, petrification = 7, stun = 10, charm1 = 14, charm2 = 17, terror = 28,
               chocobo = 252, lullaby = 193, silence = 6, mute = 29, amnesia = 16, bind = 11, bio = 135, dia = 134,
               frost = 129, burn = 128, choke = 131, rasp = 130, shock = 132, drown = 133, requiem = 192, disease = 8,
               plague = 31, helix = 186, chainspell = 48 }
local function has(player, ...)
    for _, k in ipairs({ ... }) do if util.has_buff(player.buffs, BUFF[k]) then return true end end
    return false
end
local CONTROL = { 'charm1', 'charm2', 'petrification', 'sleep', 'sleep2', 'stun', 'chocobo', 'terror', 'lullaby' }
local function control(player)
    for _, k in ipairs(CONTROL) do if has(player, k) then return true end end
    return false
end
local function dots(player)
    return has(player, 'bio', 'poison', 'frost', 'burn', 'choke', 'rasp', 'shock', 'drown', 'dia', 'requiem', 'disease', 'helix', 'plague')
end

local function party_ids()
    local ids, list = {}, {}
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        local m = p[k]
        if m and m.name then
            list[#list + 1] = m
            local mob = m.mob or (m.name and windower.ffxi.get_mob_by_name(m.name))
            if mob and mob.id then ids[mob.id] = true end
        end
    end
    return ids, list
end

local function my_id() local p = windower.ffxi.get_player() return p and p.id end
-- EasyFarm's Unit properties
local function claimed(m) return (m.claim_id or 0) ~= 0 end
local function my_claim(m) return m.claim_id == my_id() end
local function party_claim(m, ids) return claimed(m) and ids[m.claim_id] == true end
local function fighting(m) return m.status == 1 end
local function has_aggroed(m) return (not claimed(m) or my_claim(m)) and fighting(m) end
local function dead(m) return m.status == 2 or m.status == 3 or (m.hpp or 0) <= 0 end
local function dist(m) return util.dist(m) end

local function match_any(name, patterns)
    name = (name or ''):lower()
    for _, p in ipairs(patterns) do
        local q = util.trim(p):lower()
        if q ~= '' and name:find(q, 1, true) then return true end
    end
    return false
end

local function route()
    local pts = {}
    for _, p in ipairs(util.split(S.farm.route or '', ';')) do
        local x, y, z = p:match('^(%-?[%d%.]+):(%-?[%d%.]+):(%-?[%d%.]+)$')
        if x then pts[#pts + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
    end
    return pts
end
local ROUTE

-- UnitFilters.MobFilter
function ef.mob_filter(mob, ids)
    if type(mob) ~= 'table' or not mob.id then return false end
    local m = windower.ffxi.get_mob_by_id(mob.id)                     -- fresh
    if not m then return false end
    if m.valid_target == false then return false end                -- IsActive / IsRendered
    if dead(m) then return false end
    if not m.is_npc or m.spawn_type ~= 16 then return false end      -- NpcType.Mob (not a pet / NPC / player)
    if not (dist(m) < C.detect) then return false end
    if #ROUTE > 0 then
        local near = false
        for _, w in ipairs(ROUTE) do
            local dx, dy = m.x - w.x, m.y - w.y
            if math.sqrt(dx * dx + dy * dy) <= C.wander then near = true break end
        end
        if not near then return false end
    end
    local me = windower.ffxi.get_mob_by_target('me')
    if me and math.abs((m.z or 0) - (me.z or 0)) > C.height then return false end
    if match_any(m.name, C.ignored) then return false end
    if has_aggroed(m) and C.aggro then return true end
    if not match_any(m.name, C.targets) and #C.targets > 0 then return false end
    if party_claim(m, ids) and C.party then return true end
    if not claimed(m) and C.unclaimed then return true end
    if claimed(m) and C.claimed then return true end
    return my_claim(m)
end

------------------------------------------------------------------------
-- Actions (BattleAbility + ActionFilters + Executor)
------------------------------------------------------------------------
local BL                                 -- vg_blist (the lists, edited in the app)
local function meta(list, a)
    state.ef_meta = state.ef_meta or {}
    local k = list .. ':' .. a.n
    state.ef_meta[k] = state.ef_meta[k] or { last = 0, uses = 0 }
    return state.ef_meta[k]
end

local function kind_of(name)
    local kind, r = BL.kind(name)
    return kind, r
end
-- the command's target, as EasyFarm's Auto-Fill sets it from the resources
local function target_of(kind, r)
    if kind == 'ws' or kind == 'ra' then return '<t>' end
    if kind == 'trust' then return '<me>' end
    if r and r.targets then
        local t = r.targets
        local enemy = (type(t) == 'table' and (t.Enemy or t[32])) or (type(t) == 'number' and t % 64 >= 32)
        if util.targets then enemy = util.targets(r, 'Enemy') and not util.targets(r, 'Self') end
        return enemy and '<t>' or '<me>'
    end
    return '<me>'
end

local function recastable(kind, r, player)              -- AbilityUtils.IsRecastable
    if kind == 'ws' or kind == 'ra' then return true end
    if kind == 'ma' or kind == 'trust' then
        local rc = (windower.ffxi.get_spell_recasts() or {})[r.recast_id]
        return not rc or rc <= 0
    end
    if kind == 'ja' then return util.ability_ready(r) end
    return true
end

local function in_range(lo, hi, v)                     -- Range.InRange / NotSet
    if (lo or 0) == 0 and (hi or 0) == 0 then return true end
    return v >= lo and v <= hi
end

local function any_aggro(ids)
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if type(m) == 'table' and m.is_npc and m.spawn_type == 16 and not dead(m) and has_aggroed(m) then return true end
    end
    return false
end

-- ActionFilters.BuffingFilter
function ef.buffing_ok(list, a, player, ids)
    if tonumber(a.on) ~= 1 or (a.n or '') == '' then return false end
    local kind, r = kind_of(a.n)
    if not kind then return false end
    local v = player.vitals
    if (kind == 'ma' or kind == 'trust') and r and (r.mp_cost or 0) > v.mp then return false end
    -- a spell this character can't cast (not learned, not this job): EasyFarm's EnsureCast fails on it; here it
    -- doesn't count as usable at all (his report 2026-10-21: a trust that never went out held up every pull)
    if (kind == 'ma' or kind == 'trust') and r and util.can_cast and not util.can_cast(r, player) then return false end
    if kind == 'trust' then
        local fail = (state.ef_trust_fail or {})[r.en]
        if fail and fail > clock() then return false end
        local p = windower.ffxi.get_party() or {}
        local leader = p.party1_leader
        if leader and leader ~= 0 and leader ~= player.id and p.p1 and p.p1.name then return false end   -- only the leader calls trusts
    end
    if kind == 'ws' and v.tp < 1000 then return false end
    if kind == 'ja' and r and (r.tp_cost or 0) > v.tp then return false end
    if (v.max_mp or 0) > 0 and not in_range(a.ml, a.mh, v.mpp) then return false end
    if not in_range(a.tpl, a.tph, v.tp) then return false end
    local m = meta(list, a)
    if (a.lim or 0) ~= 0 and m.uses >= a.lim then return false end
    if not recastable(kind, r, player) then return false end
    if (kind == 'ma' or kind == 'trust') and (has(player, 'silence', 'mute') or control(player)) then return false end
    if (kind == 'ja' or kind == 'ws') and (has(player, 'amnesia') or control(player)) then return false end
    if ((a.pl or 0) ~= 0 or (a.ph or 0) ~= 0) and (v.hpp > a.ph or v.hpp < a.pl) then return false end
    if (a.st or '') ~= '' then
        local id = util.buff_id(a.st)
        local present = id and util.has_buff(player.buffs, id) or false
        if present and tonumber(a.sp) ~= 1 then return false end
        if not present and tonumber(a.sp) == 1 then return false end
    end
    if (a.rc or 0) ~= 0 and m.last > clock() then return false end
    if kind == 'trust' and any_aggro(ids) then return false end
    return true
end

-- ActionFilters.TargetedFilter
function ef.targeted_ok(list, a, player, ids, unit)
    if not ef.buffing_ok(list, a, player, ids) then return false end
    if ((a.tl or 0) ~= 0 or (a.th or 0) ~= 0) and ((unit.hpp or 0) > a.th or (unit.hpp or 0) < a.tl) then return false end
    if (a.tn or '') ~= '' and not (unit.name or ''):lower():find(a.tn:lower(), 1, true) then return false end
    return true
end

------------------------------------------------------------------------
-- Moving, facing, targeting (EasyFarm's Navigator and Player.SetTarget)
------------------------------------------------------------------------
local function reset_nav() h.stop_running() end
local function goto_pos(me, pos, tol)                   -- Navigator.GotoNPC / GotoWaypoint, one step per pass
    local dx, dy = pos.x - me.x, pos.y - me.y
    if math.sqrt(dx * dx + dy * dy) <= tol then reset_nav() return true end
    h.run_toward(me, pos)
    return false
end
local function face(me, mob) h.face(me, mob) end

-- Player.SetTarget (memory) -> normal commands: the party's mob with /ta <bt>, else /targetbnpc (nearest enemy)
local function set_target(target)
    local t = windower.ffxi.get_mob_by_target('t')
    if t and t.id == target.id then return true end
    if h.recently('ef:target', 1) then return false end
    h.mark('ef:target')
    local bt = windower.ffxi.get_mob_by_target('bt')
    if bt and bt.id == target.id then windower.send_command('input /ta <bt>')
    else windower.send_command('input /targetbnpc') end
    return false
end

-- one action, the Executor way (CastSpell / CastAbility); true when it was sent
local function use(list, a, target, player)
    local kind, r = kind_of(a.n)
    if not kind then return false end
    local tgt = target_of(kind, r)
    local sent = false
    if kind == 'ma' or kind == 'trust' then
        sent = h.try_cast(r.en, tgt, 'EasyFarm ' .. list, player)
    elseif kind == 'ja' then
        windower.send_command(('input /ja "%s" %s'):format(r.en, tgt)) sent = true
    elseif kind == 'ws' then
        sent = h.use_ws(r.en)
    elseif kind == 'item' then
        windower.send_command(('input /item "%s" %s'):format(r.en, tgt)) sent = true
    elseif kind == 'ra' then
        windower.send_command('input /ra <t>') sent = true
    end
    local m = meta(list, a)
    m.uses = m.uses + 1
    m.last = clock() + (a.rc or 0)
    -- TimeWaiter.Pause(GlobalCooldown) after each action (+ the cast itself: MonitorCast)
    local cast = (kind == 'ma' or kind == 'trust') and r and (r.cast_time or 0) or 0
    state.ef_wait = clock() + C.gcd + cast + 0.1
    if sent then h.log(('[EasyFarm] %s%s'):format(r and r.en or a.n, target and (' -> ' .. target.name) or '')) end
    return sent
end

-- Executor.UseTargetedActions: move into the action's distance, face, target, use (one action per pass)
local function use_targeted(list, a, target, player, me)
    local d = (a.d or 0) > 0 and a.d or 21
    if dist(target) > d then goto_pos(me, target, d) return 'moving' end
    face(me, target)
    if not set_target(target) then return 'targeting' end
    reset_nav()
    use(list, a, target, player)
    return 'used'
end
-- Executor.UseBuffingActions: the first one that passes, this pass
local function use_buffing(list, actions, player, ids)
    for _, a in ipairs(actions) do
        if ef.buffing_ok(list, a, player, ids) then use(list, a, nil, player) return true end
    end
    return false
end

------------------------------------------------------------------------
-- The states
------------------------------------------------------------------------
local M = { target = nil, fighting = false, zone = nil, route_i = 1, route = nil }
local function target_ok(ids) return M.target and ef.mob_filter(M.target, ids) end
local function list_of(name) return BL.get(name) end
local function any_enabled(name)
    for _, a in ipairs(list_of(name)) do if tonumber(a.on) == 1 then return true end end
    return false
end

local Rest, Trusts, Healing          -- (checks used by other states)

Rest = {
    check = function(player, ids)
        if dots(player) then return false end
        if any_aggro(ids) then return false end
        if player.status == 1 then return false end
        local v = player.vitals
        local healing = player.status == 33
        if C.rest_hp and (v.hpp <= C.hp_low or (v.hpp < C.hp_high and healing)) then return true end
        if C.rest_mp and (v.mpp <= C.mp_low or (v.mpp < C.mp_high and healing)) then return true end
        return false
    end,
    run = function(player)
        if player.status ~= 33 and not h.recently('ef:heal', 2) then h.mark('ef:heal') windower.send_command('input /heal on') end
    end,
    exit = function(player)
        if player.status == 33 then windower.send_command('input /heal off') end
    end,
}

-- SummonTrustsState
local function trust_in_party(name, plist)
    local comp = name:gsub(' %(UC%)', ''):gsub(' II', ''):gsub('AA', 'Ark'):gsub(' ', '')
    for i = 2, #plist do
        if plist[i].name == comp then
            if state.ef_trust_tries then state.ef_trust_tries[name] = nil end
            return true
        end
    end
    return false
end
local function party_has_space(plist) return #plist < 6 end
local function trusts_count(plist)
    local n = 0
    for i = 2, #plist do
        local mob = plist[i].mob or windower.ffxi.get_mob_by_name(plist[i].name)
        if mob and mob.is_npc then n = n + 1 end
    end
    return n
end
Trusts = {
    check = function(player, ids, plist)
        if Rest.check(player, ids) then return false end
        if player.status ~= 0 then return false end
        for _, t in ipairs(list_of('trusts')) do
            if tonumber(t.on) == 1 and ef.buffing_ok('trusts', t, player, ids) then
                if not trust_in_party(t.n, plist) and party_has_space(plist) and trusts_count(plist) < C.trust_size then return true end
            end
        end
        return false
    end,
    run = function(player, ids, plist)
        if player.status == 1 then return end
        for _, t in ipairs(list_of('trusts')) do
            if tonumber(t.on) == 1 and not trust_in_party(t.n, plist) and party_has_space(plist) and ef.buffing_ok('trusts', t, player, ids) then
                state.ef_trust_tries = state.ef_trust_tries or {}
                local tr = state.ef_trust_tries[t.n]
                if tr and clock() - tr > 20 then
                    -- called 20 s ago and still not here (not allowed in this area, the party is full...): skip it
                    state.ef_trust_fail = state.ef_trust_fail or {}
                    state.ef_trust_fail[t.n] = clock() + 120
                    state.ef_trust_tries[t.n] = nil
                    h.log(("[EasyFarm] %s didn't join: skipping it for 2 minutes"):format(t.n))
                    return
                end
                if use('trusts', t, nil, player) and not tr then state.ef_trust_tries[t.n] = clock() end
                return
            end
        end
    end,
}

Healing = {
    check = function(player, ids)
        if Rest.check(player, ids) then return false end
        for _, a in ipairs(list_of('healing')) do if ef.buffing_ok('healing', a, player, ids) then return true end end
        return false
    end,
    enter = function(player)
        if player.status == 33 then windower.send_command('input /heal off') end
        reset_nav()
    end,
    run = function(player, ids) use_buffing('healing', list_of('healing'), player, ids) end,
}

local STATES = {
    { name = 'Dead', pri = 7,
      check = function(player) return player.status == 2 or player.status == 3 end,
      run = function()
          reset_nav()
          if not h.recently('ef:dead', 10) then
              h.mark('ef:dead')
              h.log('[EasyFarm] KO: pausing')
              windower.send_command('vg farming pause')
          end
      end },
    { name = 'Zone', pri = 7,
      check = function()
          local z = (windower.ffxi.get_info() or {}).zone
          return M.zone ~= nil and z ~= M.zone
      end,
      run = function()
          M.zone = (windower.ffxi.get_info() or {}).zone
          M.target = nil
          reset_nav()
      end },
    { name = 'SetTarget', pri = 7,
      check = function(player, ids)
          if not target_ok(ids) then
              if h.recently('ef:scan', 1) then return false end            -- UnitArrayCheckRate 1 s
              h.mark('ef:scan')
              local best, bk
              for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
                  if type(m) == 'table' and m.is_npc and m.spawn_type == 16 and ef.mob_filter(m, ids) then
                      -- PartyClaim first, then HasAggroed, then the nearest
                      local k = { party_claim(m, ids) and 0 or 1, has_aggroed(m) and 0 or 1, dist(m) }
                      if not bk or k[1] < bk[1] or (k[1] == bk[1] and (k[2] < bk[2] or (k[2] == bk[2] and k[3] < bk[3]))) then best, bk = m, k end
                  end
              end
              M.target = best
              if best then h.log(('[EasyFarm] Now targeting %s : %d'):format(best.name, best.id)) end
          end
          return false
      end },
    { name = 'SetFighting', pri = 7,
      check = function(player, ids)
          if target_ok(ids) then
              local t = windower.ffxi.get_mob_by_id(M.target.id)
              if not any_enabled('pull') then M.fighting = true return true end
              M.fighting = fighting(t)
              return M.fighting
          end
          M.fighting = false
          return false
      end },
    { name = 'SummonTrusts', pri = 6, check = function(...) return Trusts.check(...) end, run = function(...) Trusts.run(...) end },
    { name = 'Follow', pri = 5,
      check = function(player, ids)
          if M.fighting then return false end
          if Rest.check(player, ids) then return false end
          if C.follow == '' then return false end
          local p = windower.ffxi.get_mob_by_name(C.follow)
          if not p then return false end
          return dist(p) > C.follow_dist
      end,
      enter = function(player)
          if player.status == 33 then windower.send_command('input /heal off') end
          if player.status == 1 then windower.send_command('input /attack off') end
      end,
      run = function(player, ids, plist, me)
          local p = windower.ffxi.get_mob_by_name(C.follow)
          if p then goto_pos(me, p, C.follow_dist) end
      end },
    { name = 'Start', pri = 5,
      check = function(player, ids)
          if Rest.check(player, ids) then return false end
          if not target_ok(ids) then return false end
          return not fighting(windower.ffxi.get_mob_by_id(M.target.id))
      end,
      enter = function() reset_nav() end,
      run = function(player, ids) use_buffing('start', list_of('start'), player, ids) end },
    { name = 'Pull', pri = 4,
      check = function(player, ids, plist)
          if M.fighting then return false end
          if Rest.check(player, ids) then return false end
          if Trusts.check(player, ids, plist) then return false end
          if not target_ok(ids) then return false end
          return any_enabled('pull')
      end,
      enter = function() reset_nav() end,
      run = function(player, ids, plist, me)
          local t = windower.ffxi.get_mob_by_id(M.target.id)
          for _, a in ipairs(list_of('pull')) do
              if ef.targeted_ok('pull', a, player, ids, t) then
                  if use_targeted('pull', a, t, player, me) == 'used' then M.pulled = t.id end
                  return
              end
          end
      end },
    { name = 'Battle', pri = 3,
      check = function(player, ids, plist)
          if Rest.check(player, ids) then return false end
          if Trusts.check(player, ids, plist) then return false end
          if not M.fighting then return false end
          if not target_ok(ids) then return false end
          if C.engage then return player.status == 1 end
          return true
      end,
      enter = function(player)
          if player.status == 33 then windower.send_command('input /heal off') end
          reset_nav()
      end,
      run = function(player, ids, plist, me)
          local t = windower.ffxi.get_mob_by_id(M.target.id)
          for _, a in ipairs(list_of('battle')) do
              if ef.targeted_ok('battle', a, player, ids, t) then use_targeted('battle', a, t, player, me) return end
          end
      end },
    { name = 'End', pri = 3,
      check = function(player, ids)
          if Rest.check(player, ids) then return false end
          return not target_ok(ids)
      end,
      enter = function(player)
          reset_nav()
          if player.status == 1 then windower.send_command('input /attack off') end
      end,
      run = function(player, ids)
          use_buffing('finish', list_of('finish'), player, ids)
          for k, m in pairs(state.ef_meta or {}) do m.uses = 0 end          -- action.Usages = 0
      end },
    { name = 'Rest', pri = 2, check = function(...) return Rest.check(...) end, run = function(p) Rest.run(p) end,
      exit = function(p) Rest.exit(p) end },
    { name = 'Weaponskill', pri = 2,
      check = function(player, ids)
          if Rest.check(player, ids) then return false end
          if not target_ok(ids) then return false end
          return player.status == 1
      end,
      run = function(player, ids, plist, me)
          if player.status ~= 1 then return end
          local t = windower.ffxi.get_mob_by_id(M.target.id)
          for _, a in ipairs(list_of('ws')) do
              if ef.targeted_ok('ws', a, player, ids, t) then use_targeted('ws', a, t, player, me) return end
          end
      end },
    { name = 'Healing', pri = 2, check = function(...) return Healing.check(...) end, enter = function(p) Healing.enter(p) end,
      run = function(p, ids) Healing.run(p, ids) end },
    { name = 'Travel', pri = 1,
      check = function(player, ids, plist)
          if #ROUTE == 0 then return false end
          if target_ok(ids) then return false end
          if Rest.check(player, ids) then return false end
          if Healing.check(player, ids) then return false end
          if Trusts.check(player, ids, plist) then return false end
          if has(player, 'bind') or control(player) then return false end
          return true
      end,
      run = function(player, ids, plist, me)
          -- Route.GetNextPosition: the next waypoint (the nearest when more than 15 away); a straight route turns
          -- round at its end, a circular one starts over
          local pts = M.route or ROUTE
          if M.route_i > #pts then
              if S.farm.loop == false then
                  local rev = {}
                  for i = #pts, 1, -1 do rev[#rev + 1] = pts[i] end
                  M.route, pts = rev, rev
              end
              M.route_i = 1
          end
          local w = pts[M.route_i]
          local dx, dy = w.x - me.x, w.y - me.y
          local dw = math.sqrt(dx * dx + dy * dy)
          if dw > 15 then
              local best, bd = 1, nil
              for i, p in ipairs(pts) do
                  local ex, ey = p.x - me.x, p.y - me.y
                  local d = math.sqrt(ex * ex + ey * ey)
                  if not bd or d < bd then best, bd = i, d end
              end
              -- (only a jump to a nearer point: with waypoints far apart it kept going back to the one it stood on)
              if bd and bd < dw and best ~= M.route_i - 1 then M.route_i = best w = pts[best] end
          end
          if goto_pos(me, w, 1) then M.route_i = M.route_i + 1 end
      end,
      exit = function() reset_nav() end },
    { name = 'Approach', pri = 0,
      check = function(player, ids, plist)
          if Rest.check(player, ids) then return false end
          if Trusts.check(player, ids, plist) then return false end
          if not target_ok(ids) then return false end
          local t = windower.ffxi.get_mob_by_id(M.target.id)
          if fighting(t) then return true end
          local usable = false
          for _, a in ipairs(list_of('pull')) do if ef.buffing_ok('pull', a, player, ids) then usable = true break end end
          if not usable then return true end
          return dist(t) < 8
      end,
      run = function(player, ids, plist, me)
          local t = windower.ffxi.get_mob_by_id(M.target.id)
          if C.approach and dist(t) > C.melee then goto_pos(me, t, C.melee) elseif not C.approach then reset_nav() end
          face(me, t)
          local targeted = set_target(t)
          if C.engage and targeted and player.status ~= 1 and dist(t) < 25 and not h.recently('ef:attack', 2) then
              h.mark('ef:attack')
              windower.send_command('input /attack <t>')
          end
      end },
}

------------------------------------------------------------------------
-- The loop (FiniteStateMachine.RunStateMachine), one pass per call
------------------------------------------------------------------------
function ef.active()
    return S.modules.farm and S.enabled and (S.farm.engine or 'easyfarm') == 'easyfarm'
end

-- the state that is doing something now, for the app's status bar
local function describe(name, player)
    local t = M.target and windower.ffxi.get_mob_by_id(M.target.id)
    local tn = t and t.name or 'a mob'
    return ({ Dead = 'KO', Zone = 'zoning', SummonTrusts = 'calling trusts', Follow = 'following ' .. C.follow,
              Start = 'starting on ' .. tn, Pull = 'pulling ' .. tn, Battle = 'fighting ' .. tn, End = 'no target',
              Rest = 'resting', Weaponskill = 'fighting ' .. tn, Healing = 'healing', Travel = 'walking the route',
              Approach = (player.status == 1 and 'fighting ' or 'approaching ') .. tn })[name] or name
end

function ef.start()
    -- StartEngineState: every action's recast timer starts now; a fresh machine
    state.ef_meta, state.ef_cache, state.ef_wait = {}, {}, 0
    M.target, M.fighting, M.route_i, M.route = nil, false, 1, nil
    M.zone = (windower.ffxi.get_info() or {}).zone
    M.started = true
end

function ef.tick(player)
    C = cfg()
    BL = BL or require('vg_blist')
    ROUTE = route()
    if not M.started then ef.start() end
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return true end
    -- the Executor's waits (global cooldown, a cast in progress): EasyFarm's thread sleeps; nothing happens meanwhile
    if (state.ef_wait or 0) > clock() or (state.busy_until or 0) > clock() then return true end
    local ids, plist = party_ids()
    state.ef_cache = state.ef_cache or {}
    local doing
    for _, st in ipairs(STATES) do                                 -- (already in priority order)
        local ok, runnable = pcall(st.check, player, ids, plist, me)
        runnable = ok and runnable or false
        if state.ef_cache[st.name] ~= runnable then
            if runnable and st.enter then pcall(st.enter, player, ids, plist, me) end
            if not runnable and st.exit then pcall(st.exit, player, ids, plist, me) end
            state.ef_cache[st.name] = runnable
        end
        if runnable and st.run then
            local okr, err = pcall(st.run, player, ids, plist, me)
            if not okr then h.log('[EasyFarm] ' .. st.name .. ': ' .. tostring(err)) end
            if st.name ~= 'SetFighting' and st.name ~= 'SetTarget' then doing = doing or st.name end
        end
        if (state.ef_wait or 0) > clock() then break end           -- an action went out: the pause starts now
    end
    if h.status then h.status(doing and describe(doing, player) or 'looking for a target') end
    return true
end

function ef.target() return M.target end                           -- (for the tests)
function ef.states() return STATES end

function ef.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return ef
