--[[
Vanguard: whole-team commands (round 6, 2026-10-15; after Trust's profiles and its exp/cp/ep scenario).

  //vg setup save <name>     on the leader: every character saves its current setup under that name
                             (its job's role / weapon skill / abilities / menus, leader, formation, assist,
                             farm targets, food / Reraise / mount)
  //vg setup load <name>     every character puts that setup back (applies now if it's on the same job,
                             otherwise when it changes to that job)
  //vg setup list | delete <name>
  //vg exp [mob names]       XP / CP / EP party in one go: this character pulls (farm on, camp here), the alts
                             assist and fight at camp.        //vg exp off   ("cp" and "ep" work too)

The leader's order goes to the others over Windower's local IPC ("vg_setup", "vg_mode").
]]

local team = {}
local S, state, h

local function valid(name) return name and name:match('^[%w_]+$') ~= nil end

------------------------------------------------------------------------
-- Team setups
------------------------------------------------------------------------
function team.save(player, name)
    if not valid(name) then h.log('Setup names: letters, digits and _ only (e.g. Odyssey, Exp_party)') return false end
    local job = player.main_job
    h.save_profile()
    S.setups[name] = {
        job = job, profile = S.profiles[job] or '', menu = S.menus[job] or '',
        leader = S.leader, formation = S.follow.formation, assist = S.modules.assist and 'on' or 'off',
        approach = S.assist.approach and 'on' or 'off', farm = S.farm.targets, pull = S.farm.pull_cmd,
        food = S.upkeep.food, reraise = S.upkeep.reraise, mount = S.mount.name,
    }
    h.store(S)
    h.log(('Setup "%s" saved (%s)'):format(name, job))
    return true
end

function team.load(player, name)
    local s = S.setups[name]
    if not s then h.log(('No setup called "%s" on this character (//vg setup list)'):format(tostring(name))) return false end
    S.profiles[s.job], S.menus[s.job] = s.profile, s.menu
    S.leader, S.follow.formation = s.leader or S.leader, s.formation or S.follow.formation
    S.farm.targets, S.farm.pull_cmd = s.farm or S.farm.targets, s.pull or S.farm.pull_cmd
    S.upkeep.food, S.upkeep.reraise, S.mount.name = s.food or '', s.reraise or '', s.mount or S.mount.name
    h.store(S)
    if player.main_job == s.job then
        h.load_profile(player)
        S.modules.assist = (s.assist == 'on')
        S.assist.approach = (s.approach ~= 'off')
        h.log(('Setup "%s" loaded'):format(name))
    else
        h.log(('Setup "%s" is for %s: it applies when this character is on %s'):format(name, s.job, s.job))
    end
    return true
end

function team.list()
    local names = {}
    for n, s in pairs(S.setups) do if type(s) == 'table' then names[#names + 1] = ('%s (%s)'):format(n, s.job or '?') end end
    table.sort(names)
    h.log(#names > 0 and ('Setups: ' .. table.concat(names, ', ')) or 'No setups saved yet (//vg setup save <name>)')
end

-- //vg setup ...: do it here and tell the others.
function team.command(player, sub, name)
    sub = (sub or 'list'):lower()
    if sub == 'save' or sub == 'load' then
        if (sub == 'save' and team.save(player, name)) or (sub == 'load' and team.load(player, name)) then
            windower.send_ipc_message(('vg_setup %s %s %s'):format(player.name, sub, name))
        end
    elseif sub == 'delete' and name then
        S.setups[name] = nil
        h.store(S)
        h.log(('Setup "%s" deleted'):format(name))
    else team.list() end
end

function team.on_setup(player, from, sub, name)
    if S.leader == '' or from:lower() ~= S.leader:lower() then return end
    if sub == 'save' then team.save(player, name) elseif sub == 'load' then team.load(player, name) end
end

------------------------------------------------------------------------
-- XP / CP / EP party in one command
------------------------------------------------------------------------
function team.exp(player, args)
    local off = (args[1] or ''):lower() == 'off'
    if off then
        S.modules.farm = false
        h.order(player, 'camp', 'off')
        windower.send_ipc_message(('vg_mode %s exp off'):format(player.name))
        h.log('XP party off')
        h.store(S)
        return
    end
    if #args > 0 then S.farm.targets = table.concat(args, ' ') end
    if (S.farm.targets or '') == '' then
        h.log('Which mobs? //vg exp <names>, e.g. //vg exp Locus Wivre, Locus Dire Bat')
        return
    end
    S.modules.farm, S.modules.assist = true, false
    S.leader = ''
    h.store(S)
    h.order(player, 'camp', '')
    windower.send_ipc_message(('vg_mode %s exp on'):format(player.name))
    h.log(('XP party: you pull %s to this camp%s; the alts fight here'):format(S.farm.targets,
        S.farm.pull_cmd ~= '' and (' with "' .. S.farm.pull_cmd .. '"') or ''))
end

function team.on_mode(player, from, mode, onoff)
    if S.leader == '' or from:lower() ~= S.leader:lower() or mode ~= 'exp' then return end
    if onoff == 'on' then
        S.modules.assist, S.modules.follow, S.modules.farm = true, true, false
        state.hold, state.retreat = false, false
        h.log('XP party with ' .. from .. ': assisting at camp')
    else
        h.log('XP party over')
    end
    h.store(S)
end

function team.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return team
