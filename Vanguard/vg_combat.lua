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
Only normal game commands.
]]

local combat = {}
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
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do if p[k] and p[k].mob then idx[p[k].mob.index] = true end end
    local best
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if m.spawn_type == 16 and m.status == 1 and m.hpp and m.hpp > 0 and m.valid_target ~= false and idx[m.target_index]
            and math.sqrt(m.distance or 9999) < 15 then
            if not best or (m.distance or 0) < (best.distance or 0) then best = m end
        end
    end
    return best
end

local PET_RECALL = { BST = 'Heel', SMN = 'Retreat', PUP = 'Retreat' }

-- Returns true when it sent a command this tick.
function combat.tick(player)
    if S.leader == '' or not S.modules.assist then return false end
    local l = h.leader_mob(player)
    local leader_fighting = l and l.status == 1

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

    -- Disengage with the leader (not while farming on my own or defending myself).
    -- (only when the leader is standing idle: if the leader is KO'd, keep fighting)
    if S.assist.disengage and player.status == 1 and l and l.status == 0 and not S.modules.farm and not state.defending then
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

function combat.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return combat
