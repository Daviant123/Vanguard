--[[
Vanguard: party forming, formation follow, hold and camp (round 2, 2026-10-14).

  //vg party               invite every character running Vanguard that isn't in your party yet;
                           they accept by themselves (/join) when the invite comes from their leader
                           (or another Vanguard character). //vg set party.accept false to stop that.
  //vg formation spread    alts stand in a fan behind the leader instead of on top of it (default)
  //vg formation line      single file behind the leader     //vg formation off   plain follow
  //vg hold  / //vg come   on the leader: the alts stop where they are / start following again
  //vg camp  / //vg camp off   on the leader: the alts go back to this spot after every fight and wait there

Trail follow (round 3, after FastFollow): the leader sends its position over IPC twice a second; when an alt
is more than a few yalms behind it follows the leader's actual path (around corners, not straight into a
wall), and when the leader zones it runs the rest of the path to the zone line and through it.
//vg set follow.trail false turns it off.

Characters find each other through Windower's local IPC ("vg_hello" every minute); everything they do
is a normal game command (/pcmd add, /join) or ordinary movement.
]]

local party = {}
local S, state, h

local function clock() return os.clock() end

------------------------------------------------------------------------
-- Who else is running Vanguard (and whom they follow)
------------------------------------------------------------------------
party.known = {}                -- name -> { leader = name, t = time }
local last_hello = -100

function party.hello(player)
    if clock() - last_hello < 60 then return end
    last_hello = clock()
    windower.send_ipc_message(('vg_hello %s %s %s'):format(player.name, S.leader ~= '' and S.leader or '-', player.main_job or ''))
end

function party.on_hello(name, leader)
    party.known[name] = { leader = (leader ~= '-' and leader or ''), t = clock() }
end

local function in_party(name)
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        if p[k] and p[k].name and p[k].name:lower() == name:lower() then return true end
    end
    return false
end

-- //vg party: invite the Vanguard characters seen in the last 5 minutes.
function party.invite_all(player)
    local names = {}
    for name, k in pairs(party.known) do
        if clock() - k.t < 300 and name:lower() ~= player.name:lower() and not in_party(name) then names[#names + 1] = name end
    end
    table.sort(names)
    if #names == 0 then h.log('Party: everyone running Vanguard is already in the party (or none seen yet).') return end
    local cmds = {}
    for i, name in ipairs(names) do
        if i > 1 then cmds[#cmds + 1] = 'wait 2' end
        cmds[#cmds + 1] = 'input /pcmd add ' .. name
    end
    windower.send_command(table.concat(cmds, '; '))
    h.log('Party: inviting ' .. table.concat(names, ', '))
end

-- A party invite arrived (from the 0x0DC packet or the chat line): accept it if it's from my leader
-- or another Vanguard character.
function party.on_invite(player, from)
    if not S.party.accept or not from or from == '' then return end
    local ok = (S.leader ~= '' and from:lower() == S.leader:lower()) or party.known[from] ~= nil
    if not ok then return end
    if h.recently('join', 5) then return end
    h.mark('join')
    windower.send_command('wait 1; input /join')
    h.log('Party: accepting the invite from ' .. from)
end

------------------------------------------------------------------------
-- Formation, hold and camp
------------------------------------------------------------------------
-- My place among the alts following the same leader (1, 2, 3, ...), alphabetical.
local function slot(player)
    local names = { player.name }
    for name, k in pairs(party.known) do
        if clock() - k.t < 300 and k.leader ~= '' and S.leader ~= '' and k.leader:lower() == S.leader:lower()
            and name:lower() ~= player.name:lower() then names[#names + 1] = name end
    end
    table.sort(names)
    for i, n in ipairs(names) do if n == player.name then return i end end
    return 1
end
party.slot = slot

local SPREAD = { -45, 45, 0, -90, 90, 180 }          -- degrees off "straight behind"

-- The spot for slot i behind a point (x, y) that faces `facing` (Windower facing: the nose points at -facing).
function party.spot(x, y, facing, i, shape, base)
    local r = base + 1
    local off = 0
    if shape == 'line' then r = base + 1.5 * i
    else off = SPREAD[((i - 1) % #SPREAD) + 1] if i >= 3 then r = r + 1.5 end end
    local a = -(facing or 0) + math.pi + math.rad(off)
    return x + r * math.cos(a), y + r * math.sin(a)
end

------------------------------------------------------------------------
-- Trail: the leader's recent positions (sent by the leader over IPC)
------------------------------------------------------------------------
local last_pos, last_pos_xy = -100, nil

-- On every character: if someone follows me, send my position twice a second (only when it changed,
-- or every 3 s while standing still).
function party.send_pos(player)
    if clock() - last_pos < 0.5 then return end
    local followed = false
    for _, k in pairs(party.known) do
        if clock() - k.t < 300 and k.leader ~= '' and k.leader:lower() == player.name:lower() then followed = true break end
    end
    if not followed then return end
    local me = windower.ffxi.get_mob_by_target('me')
    local zone = (windower.ffxi.get_info() or {}).zone
    if not me then return end
    local moved = not last_pos_xy or math.abs(me.x - last_pos_xy[1]) + math.abs(me.y - last_pos_xy[2]) > 0.3 or last_pos_xy[3] ~= zone
    if not moved and clock() - last_pos < 3 then return end
    last_pos, last_pos_xy = clock(), { me.x, me.y, zone }
    windower.send_ipc_message(('vg_pos %s %.2f %.2f %.2f %d'):format(player.name, me.x, me.y, me.z or 0, zone or 0))
end

function party.on_pos(player, from, x, y, z, zone)
    if S.leader == '' or from:lower() ~= S.leader:lower() then return end
    state.crumbs = state.crumbs or {}
    local c = state.crumbs
    local last = c[#c]
    state.leader_zone = zone
    if last and last.zone == zone and math.abs(last.x - x) + math.abs(last.y - y) < 1 then return end
    c[#c + 1] = { x = x, y = y, z = z, zone = zone, t = clock() }
    if #c > 80 then table.remove(c, 1) end
end

local function dist2(me, x, y) local dx, dy = x - me.x, y - me.y return math.sqrt(dx * dx + dy * dy) end

local function go(me, x, y, near)
    if dist2(me, x, y) > (near or 1) then h.run_toward(me, { x = x, y = y }) return true end
    h.stop_running()
    return true
end

-- Follow the trail: the crumb just after the one nearest to me (only crumbs in my zone).
local function trail_target(me, zone)
    local c = state.crumbs or {}
    local best, best_d
    for i, p in ipairs(c) do
        if p.zone == zone then
            local d = dist2(me, p.x, p.y)
            if not best_d or d < best_d then best, best_d = i, d end
        end
    end
    if not best then return nil end
    local nxt = best
    while c[nxt] and c[nxt].zone == zone and dist2(me, c[nxt].x, c[nxt].y) < 1.5 do nxt = nxt + 1 end
    if c[nxt] and c[nxt].zone == zone then return c[nxt], false end
    return c[nxt - 1], true                                  -- end of the trail in my zone
end

-- Called from Vanguard's movement step; returns true when it handled movement.
function party.movement(player, me)
    -- Retreat: drop the fight and run back to the camp spot (or the leader), then hold.
    if state.retreat then
        local zone0 = (windower.ffxi.get_info() or {}).zone
        local c = state.camp
        local l = h.leader_mob(player)
        local x, y
        if c and c.zone == zone0 then x, y = party.spot(c.x, c.y, c.facing, slot(player), S.follow.formation, 0)
        elseif l then x, y = l.x, l.y end
        if x and dist2(me, x, y) > 3 then h.run_toward(me, { x = x, y = y }) return true end
        state.retreat, state.hold = false, true
        h.stop_running()
        h.log('Retreated: holding (//vg come to follow again)')
        return true
    end
    if state.hold then h.stop_running() return true end
    local zone = (windower.ffxi.get_info() or {}).zone
    -- The leader zoned: run the rest of its path, then keep going the same way through the zone line.
    if S.modules.follow and S.follow.trail and state.leader_zone and state.leader_zone ~= zone and player.status == 0 then
        if state.zone_push_until and clock() < state.zone_push_until then
            h.run_toward(me, { x = me.x + state.zone_push[1], y = me.y + state.zone_push[2] })
            return true
        end
        local p, at_end = trail_target(me, zone)
        if p and not at_end then h.run_toward(me, p) return true end
        if p and at_end and not state.zone_push_until then
            local c = state.crumbs
            local i = #c
            while i > 1 and c[i].zone ~= zone do i = i - 1 end
            local a, b = c[i - 1] or p, c[i]
            local dx, dy = b.x - a.x, b.y - a.y
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 0.01 then dx, dy, len = p.x - me.x, p.y - me.y, math.max(0.01, dist2(me, p.x, p.y)) end
            if dist2(me, p.x, p.y) > 1.5 then h.run_toward(me, p) return true end
            state.zone_push, state.zone_push_until = { dx / len, dy / len }, clock() + 6
            h.log('Following ' .. S.leader .. ' through the zone line')
            return true
        end
        h.stop_running()
        return true
    end
    local camp = state.camp
    if camp and camp.zone == zone and player.status == 0 and not h.party_engaged(player) then
        local x, y = party.spot(camp.x, camp.y, camp.facing, slot(player), S.follow.formation, 0)
        return go(me, x, y, 1.5)
    end
    if not S.modules.follow or S.follow.formation == 'off' then return false end
    local l = h.leader_mob(player)
    if not l then return false end
    local d = math.sqrt(l.distance or 0)
    if d >= S.follow.max_distance then return false end
    if d > S.follow.distance * 4 then                                        -- far behind: catch up first
        local p = S.follow.trail and trail_target(me, zone)
        if p and dist2(me, p.x, p.y) < d then h.run_toward(me, p) else h.run_toward(me, l) end
        return true
    end
    local x, y = party.spot(l.x, l.y, l.facing, slot(player), S.follow.formation, S.follow.distance)
    return go(me, x, y, 1)
end

-- //vg hold / come / camp on the leader: tell the alts.
function party.order(player, what, arg)
    if what == 'retreat' then
        windower.send_ipc_message(('vg_hold %s retreat'):format(player.name))
        h.log('Retreat: the alts stop fighting and come back to you (then hold; //vg come)')
        return
    end
    if what == 'hold' or what == 'come' then
        state.hold = (what == 'hold')
        windower.send_ipc_message(('vg_hold %s %s'):format(player.name, what))
        h.log(what == 'hold' and 'Hold: the alts stay where they are (//vg come to follow again)' or 'Come: the alts follow again')
    elseif what == 'camp' then
        if arg == 'off' then
            state.camp, state.my_camp = nil, nil
            windower.send_ipc_message(('vg_camp %s off'):format(player.name))
            h.log('Camp off: the alts follow again')
        else
            local me = windower.ffxi.get_mob_by_target('me')
            local zone = (windower.ffxi.get_info() or {}).zone
            if not me then return end
            windower.send_ipc_message(('vg_camp %s %.2f %.2f %.3f %d'):format(player.name, me.x, me.y, me.facing or 0, zone or 0))
            state.my_camp = { x = me.x, y = me.y, zone = zone }      -- a puller brings mobs back here
            h.log('Camp set here: the alts come back to this spot after every fight (//vg camp off)')
        end
    end
end

function party.on_order(player, from, what, rest)
    if S.leader == '' or from:lower() ~= S.leader:lower() then return end
    if what == 'hold' and rest == 'retreat' then
        state.retreat, state.hold = true, false
        h.log('Retreating to ' .. from)
    elseif what == 'hold' then state.hold = (rest == 'hold') state.retreat = false
        h.log(state.hold and ('Holding (by ' .. from .. ')') or ('Following ' .. from .. ' again'))
    elseif what == 'camp' then
        if rest == 'off' then state.camp = nil h.log('Camp off') return end
        local x, y, f, z = rest:match('^(%-?[%d.]+) (%-?[%d.]+) (%-?[%d.]+) (%d+)$')
        if x then
            state.camp = { x = tonumber(x), y = tonumber(y), facing = tonumber(f), zone = tonumber(z) }
            h.log('Camp set by ' .. from)
        end
    end
end

-- Pull to camp: the farmer has pulled its target (farm.pull_cmd) and has its own camp: run back to camp
-- and wait there for the mob, instead of chasing it. Returns true when it handled movement.
function party.pull_to_camp(player, me, t)
    local camp = state.my_camp
    local zone = (windower.ffxi.get_info() or {}).zone
    if not camp or camp.zone ~= zone or not S.modules.farm or not t or not state.farm_pulled[t.id] then return false end
    local td = math.sqrt(t.distance or 0)
    if td <= S.assist.melee_range + 0.5 then return false end                 -- it's here: fight normally
    if dist2(me, camp.x, camp.y) > 2 then h.run_toward(me, camp) return true end
    h.stop_running()
    h.face(me, t)
    return true
end

function party.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return party
