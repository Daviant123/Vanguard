--[[
Vanguard: finishing weapon skill (his request 2026-10-16: "I need to kill the monster with Atonement, there is no way
in Vanguard to guarantee that can happen"). EasyFarm lets a weapon skill fire by the mob's HP; this goes further, for
trials that need the killing blow to be a set weapon skill, with several characters hitting the same mob:

  ws.finish        the weapon skill that should land the kill ('' = off)
  ws.finish_at     use it once the mob's HP is at or under this % (and TP is 1000+); 0 = Auto: learn how much of each
                   kind of mob one hit takes (HP % just before and 1.5 s after it lands) and use it once the mob is
                   low enough for one hit to kill it (his report 2026-10-17: "it uses atonement so early the mob
                   doesnt get killed by atonement"). Auto always saves TP for it.
  ws.finish_save   save TP for it: the normal weapon skill isn't used while a finisher is set
  ws.finish_others the other characters stop attacking that mob once it's that low (they keep curing / buffing)
  ws.finish_wait   if the mob gets that low before TP is ready, stop attacking until TP is 1000 (a tank still gains
                   TP from being hit), then attack again and finish it

Normal game commands only (/ws, /attackoff, /attack). The "stop attacking" order to the others goes over Windower IPC
on this PC (vg_finish <mob id> <name>).
]]

local finish = {}
local S, state, h

local function clock() return os.clock() end

local function on(name) return name and name ~= '' and name:lower() ~= 'none' end

-- Auto finish point: per kind of mob, the HP % recent hits took (newest last) and the highest HP % a hit has killed at
local learned, killed_at = {}, {}

local function auto() return (tonumber(S.ws.finish_at) or 25) <= 0 end

-- The mob's HP % at which the finishing weapon skill should go off.
function finish.line(t)
    if not auto() then return tonumber(S.ws.finish_at) or 25 end
    local l = learned[t.name]
    if l and #l > 0 then
        local low = l[1]
        for _, v in ipairs(l) do if v < low then low = v end end
        -- the weakest recent hit, less a tenth (others keep hitting while it goes off), never under 3 %
        return math.max(3, math.floor(low * 0.9))
    end
    return killed_at[t.name] or 30                    -- nothing learned yet: a careful first guess, learned from
end

-- Waiting for TP (finish_wait, or always while helping with a Magian trial): with Auto, stop attacking a little above
-- the finish line - by the time the mob is under it, a couple of normal hits kill it before TP is 1000 (his real run,
-- 2026-10-17: Atonement landed 42 of 66 Peapuk kills, the line being 9 %).
local function waits() return S.ws.finish_wait or (S.trial_assist and S.trial_assist ~= '') end

function finish.wait_line(t)
    local line = finish.line(t)
    if not waits() or not auto() then return line end
    return line + math.max(5, line)
end

-- Our weapon skill hit something (from the 'action' event): if it's the finisher, measure what it does.
function finish.note_ws(target_id, ws_name)
    if not on(S.ws.finish) or not ws_name or ws_name:lower() ~= S.ws.finish:lower() then return end
    local m = windower.ffxi.get_mob_by_id(target_id)
    if not m or not m.name then return end
    local seen = state.finish_seen and state.finish_seen.id == target_id and state.finish_seen.hpp or 0
    local before = math.max(seen, m.hpp or 0)
    if before <= 0 then return end
    state.finish_probe = { id = target_id, name = m.name, before = before, t = clock() }
end

function finish.learn_tick()
    local p = state.finish_probe
    if not p or clock() - p.t < 1.5 then return end
    state.finish_probe = nil
    local m = windower.ffxi.get_mob_by_id(p.id)
    if not m or (m.hpp or 0) <= 0 or m.valid_target == false or m.status == 2 or m.status == 3 then
        killed_at[p.name] = math.max(killed_at[p.name] or 0, p.before)      -- it killed: one hit is at least that much
        return
    end
    local drop = p.before - m.hpp
    if drop <= 0 then return end
    local l = learned[p.name] or {}
    l[#l + 1] = drop
    while #l > 5 do table.remove(l, 1) end
    learned[p.name] = l
    if auto() then h.log(('%s took %d%% of %s: it will finish them from %d%% HP'):format(S.ws.finish, drop, p.name, finish.line(m))) end
end

-- For the app: what Auto has learned
function finish.learned_list()
    local out = {}
    for name in pairs(learned) do out[#out + 1] = { n = name, at = finish.line({ name = name }) } end
    for name, v in pairs(killed_at) do if not learned[name] then out[#out + 1] = { n = name, at = finish.line({ name = name }) } end end
    table.sort(out, function(a, b) return a.n < b.n end)
    return out
end

-- On the finisher, from do_ws. Returns 'used' (weapon skill sent), 'block' (no normal weapon skill now) or nil.
function finish.ws(player, t)
    local f = S.ws.finish
    if not on(f) or not t or not t.hpp or t.hpp <= 0 then return nil end
    finish.learn_tick()
    state.finish_seen = { id = t.id, hpp = t.hpp }
    local line = finish.line(t)
    if t.hpp > line and t.hpp <= finish.wait_line(t) and player.vitals.tp < 1000 then
        -- close to the line without TP: stop now (the others too), attack again when TP is 1000
        if S.ws.finish_others and state.finish_told ~= t.id then
            state.finish_told = t.id
            windower.send_ipc_message(('vg_finish %d %s'):format(t.id, player.name))
        end
        if player.status == 1 and state.finish_wait ~= t.id then
            state.finish_wait, state.finish_wait_t = t.id, clock()
            windower.send_command('input /attackoff')
            h.log(('%s is at %d%% and TP is %d: holding off until TP is 1000, then %s at %d%%'):format(t.name, t.hpp,
                player.vitals.tp, f, line))
            state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
        end
        return 'block'
    end
    if t.hpp <= line then
        if S.ws.finish_others and state.finish_told ~= t.id then
            state.finish_told = t.id
            windower.send_ipc_message(('vg_finish %d %s'):format(t.id, player.name))
            h.log(('%s is at %d%%: the others stop attacking, %s finishes it with %s'):format(t.name, t.hpp, player.name, f))
        end
        if player.vitals.tp >= 1000 then
            if h.ws_in_range(t, true) and not h.recently('ws:' .. f, 3) then return h.use_ws(f) and 'used' end
            return 'block'
        end
        if waits() and player.status == 1 and state.finish_wait ~= t.id then
            state.finish_wait, state.finish_wait_t = t.id, clock()
            windower.send_command('input /attackoff')
            h.log(('%s is low and TP is %d: stopping until TP is 1000, then %s'):format(t.name, player.vitals.tp, f))
            state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
        end
        return 'block'
    end
    if S.ws.finish_save or auto() then return 'block' end
    return nil
end

-- Waiting for TP after stopping (finish_wait): attack again when TP is ready. True while it's waiting (so farming /
-- assist don't re-engage early); acts once TP is there.
function finish.waiting(player)
    local id = state.finish_wait
    if not id then return false end
    local bt = windower.ffxi.get_mob_by_target('bt')
    if not bt or bt.id ~= id or (bt.hpp or 0) <= 0 then state.finish_wait = nil return false end
    if player.status == 1 then return false end
    -- TP isn't coming (the mob isn't hitting us): don't stand there forever - attack again after 30 s
    if player.vitals.tp >= 1000 or clock() - (state.finish_wait_t or clock()) > 30 then
        if not h.recently('finish:attack', 3) then
            h.mark('finish:attack')
            windower.send_command('input /attack <bt>')
            h.log('TP ready: attacking ' .. bt.name .. ' again to finish it')
            state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
        end
        return true
    end
    return true
end

-- On the others: the finisher said "leave this one to me".
function finish.on_ipc(mob_id, from)
    state.finish_hold = { id = tonumber(mob_id), from = from, t = clock() }
end

-- On the others, every tick: true while holding off a mob that's being finished (only curing / buffing then).
function finish.held(player)
    finish.learn_tick()
    local hold = state.finish_hold
    if not hold then return false end
    local m = windower.ffxi.get_mob_by_id(hold.id)
    if not m or (m.hpp or 0) <= 0 or clock() - hold.t > 120 then state.finish_hold = nil return false end
    local t = windower.ffxi.get_mob_by_target('t')
    local bt = windower.ffxi.get_mob_by_target('bt')
    local mine = (t and t.id == hold.id) or (bt and bt.id == hold.id)
    if not mine and player.status ~= 1 then return true end    -- idle: don't assist onto it either
    if player.status == 1 and t and t.id == hold.id and not h.recently('finish:off', 3) then
        h.mark('finish:off')
        windower.send_command('input /attackoff')
        h.log(('Leaving %s to %s (finishing weapon skill)'):format(m.name or 'it', hold.from))
    end
    return mine or player.status ~= 1
end

function finish.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return finish
