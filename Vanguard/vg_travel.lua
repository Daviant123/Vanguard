--[[
Vanguard: travel and downtime with alts (round 4, 2026-10-15).

  Sneak & Invisible sync   When the leader is sneaked / invisible, each alt puts the same on itself:
                           Spectral Jig if it's a DNC (main or sub), else the Sneak / Invisible spell if it
                           knows it, else a Silent Oil / Prism Powder from its inventory. Sneak first.
                           //vg stealth on|off
  Rest sync                When the leader rests (/heal), alts that aren't full rest too; when the leader
                           stands up, the alts that rested with it stand up.   //vg restsync on|off

The leader's state goes out over Windower's local IPC ("vg_lstate <name> <sneak><invis><resting>"),
on change and every 10 s while any is on. Only normal game commands; nothing happens during a fight.
]]

local res = require('resources')

local travel = {}
local S, state, h

local SNEAK, INVIS = 71, 69
local function clock() return os.clock() end
local function has(list, id) for _, b in ipairs(list or {}) do if b == id then return true end end return false end

------------------------------------------------------------------------
-- Leader side: announce sneak / invisible / resting
------------------------------------------------------------------------
local last_flags, last_sent = nil, -100

function travel.broadcast(player)
    local flags = (has(player.buffs, SNEAK) and '1' or '0') .. (has(player.buffs, INVIS) and '1' or '0')
        .. (player.status == 33 and '1' or '0')
    if flags ~= last_flags or (flags ~= '000' and clock() - last_sent > 10) then
        if last_flags ~= nil or flags ~= '000' then
            windower.send_ipc_message(('vg_lstate %s %s'):format(player.name, flags))
        end
        last_flags, last_sent = flags, clock()
    end
end

function travel.on_lstate(player, from, flags)
    if S.leader == '' or from:lower() ~= S.leader:lower() then return end
    state.leader_sneak = flags:sub(1, 1) == '1'
    state.leader_invis = flags:sub(2, 2) == '1'
    state.leader_rest = flags:sub(3, 3) == '1'
end

------------------------------------------------------------------------
-- Alt side
------------------------------------------------------------------------
local ITEMS = { [SNEAK] = 'Silent Oil', [INVIS] = 'Prism Powder' }
local SPELLS = { [SNEAK] = 'Sneak', [INVIS] = 'Invisible' }

local function item_id(name)
    for id, it in pairs(res.items) do if type(it) == 'table' and it.en == name then return id end end
end
local ids = {}
local function in_inventory(name)
    ids[name] = ids[name] or item_id(name)
    for _, it in ipairs(windower.ffxi.get_items(0) or {}) do
        if type(it) == 'table' and it.id == ids[name] and (it.status or 0) == 0 then return true end
    end
    return false
end

local function jig_ready(player)
    if player.main_job ~= 'DNC' and player.sub_job ~= 'DNC' then return false end
    local ja = h.ability('Spectral Jig')
    local known = false
    for _, id in ipairs((windower.ffxi.get_abilities() or {}).job_abilities or {}) do if ja and id == ja.id then known = true end end
    return known and h.ability_ready(ja)
end

local function apply(player, buff)
    local key = 'stealth:' .. buff
    if h.recently(key, 10) then return false end
    h.mark(key)
    if jig_ready(player) then
        windower.send_command('input /ja "Spectral Jig" <me>')
        state.busy_until = clock() + 1.5
        h.log('Spectral Jig (following ' .. S.leader .. ')')
        return true
    end
    if h.try_cast(SPELLS[buff], '<me>', 'with ' .. S.leader, player) then return true end
    if in_inventory(ITEMS[buff]) then
        windower.send_command(('input /item "%s" <me>'):format(ITEMS[buff]))
        state.busy_until = clock() + 3
        h.log(ITEMS[buff] .. ' (with ' .. S.leader .. ')')
        return true
    end
    if not h.recently(key .. ':none', 300) then
        h.mark(key .. ':none')
        h.log(('No way to get %s (no spell, Spectral Jig or %s)'):format(SPELLS[buff], ITEMS[buff]))
    end
    return false
end

-- In the action chain, idle only.
function travel.tick(player)
    if S.leader == '' or player.status ~= 0 or h.party_engaged(player) then return false end
    if S.alts.stealth then
        if state.leader_sneak and not has(player.buffs, SNEAK) and apply(player, SNEAK) then return true end
        if state.leader_invis and not has(player.buffs, INVIS) and apply(player, INVIS) then return true end
    end
    if S.alts.restsync and state.leader_rest and not state.running then
        local v = player.vitals or {}
        local need = (v.hpp or 100) < 95 or ((v.max_mp or 0) > 0 and (v.mpp or 100) < 95)
        if need and not h.recently('restsync', 6) then
            h.mark('restsync')
            windower.send_command('input /heal on')
            state.resting, state.rest_synced = true, true
            h.log('Resting with ' .. S.leader)
            return true
        end
    end
    return false
end

-- While resting: stand up when the leader does (only if we sat down with it).
function travel.rest_stand(player)
    if not state.rest_synced or state.leader_rest then return false end
    if h.recently('reststand', 4) then return true end
    h.mark('reststand')
    windower.send_command('input /heal off')
    state.resting, state.rest_synced = false, false
    h.log(S.leader .. ' stood up')
    return true
end

function travel.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return travel
