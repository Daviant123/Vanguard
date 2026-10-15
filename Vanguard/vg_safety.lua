--[[
Vanguard: gear modes, getting unstuck, and not running unattended (round 8, 2026-10-15).

  GearSwap sync   //vg defense physical|magical|off   every alt switches its GearSwap defense mode
                  (Mote-style files: "gs c set DefenseMode Physical" / "gs c reset DefenseMode"; change with
                  //vg set gear.physical ..., gear.magical ..., gear.off ...).  Ctrl+F7 with //vg keys on toggles.
                  //vg gs <command>   any GearSwap command on the alts, e.g. //vg gs cycle OffenseMode
                  Auto-defense (off by default): an alt under 40% HP in a fight switches to its physical
                  defense set until it's back over 75%.            //vg set gear.auto true
  Stuck recovery  An alt that is running but hasn't moved for 2 s steps sideways (left, then right) for a
                  second and tries again; after 3 tries it tells the leader it's stuck.
  Away safety     If the leader hasn't moved or fought for away.minutes (20), the alts pause themselves and
                  say so; they carry on as soon as the leader moves.   //vg set away.minutes 0 to turn off.
]]

local safety = {}
local S, state, h

local function clock() return os.clock() end

------------------------------------------------------------------------
-- GearSwap sync
------------------------------------------------------------------------
local MODES = { physical = 'physical', phys = 'physical', pdt = 'physical', magical = 'magical', magic = 'magical',
                mdt = 'magical', off = 'off', none = 'off' }

function safety.apply_defense(mode)
    local cmd = S.gear[mode]
    if cmd and cmd ~= '' then windower.send_command(cmd) end
    state.defense = mode
end

-- On the leader: tell the alts.
function safety.defense(player, arg)
    local mode = MODES[(arg or ''):lower()]
    if arg == 'toggle' then mode = (state.defense_sent == 'physical') and 'off' or 'physical' end
    if not mode then h.log('Usage: //vg defense physical|magical|off') return end
    state.defense_sent = mode
    windower.send_ipc_message(('vg_gear %s defense %s'):format(player.name, mode))
    h.log('Alts defense: ' .. mode)
end

function safety.gs(player, rest)
    if not rest or rest == '' then h.log('Usage: //vg gs <GearSwap command>, e.g. //vg gs cycle OffenseMode') return end
    windower.send_ipc_message(('vg_gear %s gs %s'):format(player.name, rest))
    h.log('Alts: gs c ' .. rest)
end

function safety.on_gear(player, from, what, arg)
    if S.leader == '' or from:lower() ~= S.leader:lower() then return end
    if what == 'defense' and S.gear[arg] then safety.apply_defense(arg)
    elseif what == 'gs' then windower.send_command('gs c ' .. arg) end
end

-- Auto-defense on the alt itself.
function safety.auto_defense(player)
    if not S.gear.auto then return end
    local hpp = (player.vitals or {}).hpp or 100
    if player.status == 1 and hpp < 40 and state.defense ~= 'physical' then
        state.auto_defense = true
        safety.apply_defense('physical')
        h.log(('HP %d%%: defense set on'):format(hpp))
    elseif state.auto_defense and (hpp > 75 or player.status ~= 1) then
        state.auto_defense = false
        safety.apply_defense('off')
        h.log('Defense set off again')
    end
end

------------------------------------------------------------------------
-- Stuck recovery
------------------------------------------------------------------------
local watch = { x = nil, y = nil, t = 0, tries = 0, side = 1 }

-- Called every tick after movement.
function safety.watch(player)
    local me = windower.ffxi.get_mob_by_target('me')
    if not me or not state.running or (state.unstick_until and clock() < state.unstick_until) then
        if not state.running then watch.x, watch.tries = nil, 0 end
        return
    end
    if not watch.x then watch.x, watch.y, watch.t = me.x, me.y, clock() return end
    if math.abs(me.x - watch.x) + math.abs(me.y - watch.y) > 0.4 then
        watch.x, watch.y, watch.t, watch.tries = me.x, me.y, clock(), 0
        return
    end
    if clock() - watch.t < 2 then return end
    watch.tries = watch.tries + 1
    watch.t = clock()
    if watch.tries > 3 then
        if not h.recently('stuck_alert', 60) and S.leader ~= '' then
            h.mark('stuck_alert')
            windower.send_ipc_message(('vg_alert %s %s|stuck, can\'t get to you'):format(S.leader, player.name))
        end
        return
    end
    local d = state.run_dir or { 1, 0 }
    watch.side = -watch.side
    state.unstick = { -d[2] * watch.side, d[1] * watch.side }       -- 90 degrees off the way we were going
    state.unstick_until = clock() + 1
    h.log('Stuck: stepping around')
end

-- Called at the start of movement; returns true while stepping around.
function safety.unstick()
    if state.unstick_until and clock() < state.unstick_until then
        windower.ffxi.run(state.unstick[1], state.unstick[2])
        state.running = true
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Away safety (on the alt)
------------------------------------------------------------------------
local seen = { key = nil, t = clock() }

-- Returns true while paused because the leader is away.
function safety.away(player)
    local minutes = tonumber(S.away.minutes) or 0
    if minutes <= 0 or S.leader == '' then state.away = false return false end
    local l = windower.ffxi.get_mob_by_name(S.leader)
    if l then
        local key = ('%.1f,%.1f,%d'):format(l.x or 0, l.y or 0, l.status or 0)
        if key ~= seen.key then
            seen.key, seen.t = key, clock()
            if state.away then
                state.away = false
                h.log(S.leader .. ' is back: carrying on')
            end
        end
    end
    if not state.away and clock() - seen.t > minutes * 60 then
        state.away = true
        h.stop_running()
        h.log(('%s hasn\'t moved for %d min: pausing until you\'re back'):format(S.leader, minutes))
        windower.send_ipc_message(('vg_alert %s %s|paused: you\'ve been away %d min'):format(S.leader, player.name, minutes))
    end
    return state.away
end

function safety.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return safety
