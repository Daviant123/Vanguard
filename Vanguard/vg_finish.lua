--[[
Vanguard: finishing weapon skill (his request 2026-10-16: "I need to kill the monster with Atonement, there is no way
in Vanguard to guarantee that can happen"). EasyFarm lets a weapon skill fire by the mob's HP; this goes further, for
trials that need the killing blow to be a set weapon skill, with several characters hitting the same mob:

  ws.finish        the weapon skill that should land the kill ('' = off)
  ws.finish_at     use it once the mob's HP is at or under this % (and TP is 1000+)
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

-- On the finisher, from do_ws. Returns 'used' (weapon skill sent), 'block' (no normal weapon skill now) or nil.
function finish.ws(player, t)
    local f = S.ws.finish
    if not on(f) or not t or not t.hpp or t.hpp <= 0 then return nil end
    if t.hpp <= S.ws.finish_at then
        if S.ws.finish_others and state.finish_told ~= t.id then
            state.finish_told = t.id
            windower.send_ipc_message(('vg_finish %d %s'):format(t.id, player.name))
            h.log(('%s is at %d%%: the others stop attacking, %s finishes it with %s'):format(t.name, t.hpp, player.name, f))
        end
        if player.vitals.tp >= 1000 then
            if h.ws_in_range(t, true) and not h.recently('ws:' .. f, 3) then return h.use_ws(f) and 'used' end
            return 'block'
        end
        if S.ws.finish_wait and player.status == 1 and state.finish_wait ~= t.id then
            state.finish_wait = t.id
            windower.send_command('input /attackoff')
            h.log(('%s is low and TP is %d: stopping until TP is 1000, then %s'):format(t.name, player.vitals.tp, f))
            state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
        end
        return 'block'
    end
    if S.ws.finish_save then return 'block' end
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
    if player.vitals.tp >= 1000 then
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
