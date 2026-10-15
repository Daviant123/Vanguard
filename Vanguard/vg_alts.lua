--[[
Vanguard: things that make running a 2nd and 3rd character easier (round 1, 2026-10-14).

  Alerts on your main's screen   An alt tells the character it follows (its leader) when it is KO'd,
                                 low on HP, out of MP, stuck far behind / not in your zone, or standing
                                 idle while you fight. Shown in your chat (and a sound if you set one).
                                 //vg alerts on|off   //vg set alerts.hp 30   //vg set alerts.sound C:\...\ding.wav
  Mount sync                     When the leader mounts, the alts mount too; when it dismounts, they do.
                                 //vg mountsync on|off   //vg set mount.name Raptor
  Food & Reraise upkeep          Between fights each character re-eats its food and keeps Reraise up
                                 (best Reraise spell it knows with "auto", or a named spell / item).
                                 //vg food Grape Daifuku   //vg reraise auto | Reraise III | Instant Reraise | off

Only normal game commands (/mount, /dismount, /item, /ma); characters talk to each other through
Windower's local IPC (no packets). Nothing here acts in a fight: mounting and eating wait for idle.
]]

local res = require('resources')

local alts = {}
local S, state, h          -- settings, runtime state, helpers from Vanguard.lua

local BUFF_REraise, BUFF_FOOD, BUFF_MOUNTED = 113, 251, 252
local function has_buff(list, id)
    for _, b in ipairs(list or {}) do if b == id then return true end end
    return false
end
alts.has_buff = has_buff

local function clock() return os.clock() end

------------------------------------------------------------------------
-- Alerts (run on the alt; shown on the leader)
------------------------------------------------------------------------
local since = {}          -- condition key -> time it started (for "for N seconds")
local last_sent = {}      -- alert key -> time last sent

local function alert(player, key, text)
    if last_sent[key] and clock() - last_sent[key] < (tonumber(S.alerts['repeat']) or 60) then return end
    last_sent[key] = clock()
    local to = (S.leader ~= '' and S.leader) or '*'
    windower.send_ipc_message(('vg_alert %s %s|%s'):format(to, player.name, text))
    h.bridge_log(('ALERT %s'):format(text))
end

local function held(key, cond, secs)
    if not cond then since[key] = nil return false end
    since[key] = since[key] or clock()
    return clock() - since[key] >= secs
end

function alts.alerts(player)
    if not S.alts.alerts or S.leader == '' or S.leader:lower() == player.name:lower() then return end
    local v = player.vitals or {}
    if player.status == 2 or player.status == 3 then
        alert(player, 'ko', "KO'd!")
        return
    end
    last_sent.ko = nil
    -- can't act (HealBot's "player is disabled"): asleep, petrified, terrorized, charmed, stunned
    local DISABLED = { [2] = 'asleep', [19] = 'asleep', [7] = 'petrified', [28] = 'terrorized', [14] = 'charmed', [17] = 'charmed', [10] = 'stunned' }
    local what
    for _, b in ipairs(player.buffs or {}) do if DISABLED[b] then what = DISABLED[b] end end
    if held('disabled', what ~= nil, what == 'stunned' and 3 or 1) then alert(player, 'disabled', what .. '!') end
    if (v.hpp or 100) > 0 and (v.hpp or 100) < (tonumber(S.alerts.hp) or 30) then
        alert(player, 'hp', ('HP %d%%'):format(v.hpp))
    end
    if (v.max_mp or 0) > 0 and (v.mpp or 100) < (tonumber(S.alerts.mp) or 10) then
        alert(player, 'mp', ('MP %d%%'):format(v.mpp))
    end
    local leader = windower.ffxi.get_mob_by_name(S.leader)
    if held('gone', not leader, 20) then
        alert(player, 'gone', 'not in your zone')
    elseif leader then
        local d = math.sqrt(leader.distance or 0)
        if held('far', d > (tonumber(S.alerts.far) or 30), 10) then
            alert(player, 'far', ('%d yalms behind you'):format(math.floor(d)))
        end
        if held('idle', leader.status == 1 and player.status == 0 and S.modules.assist, tonumber(S.alerts.idle) or 15) then
            alert(player, 'idle', 'not fighting')
        end
    end
end

-- Received by every character; shown only on the one it's meant for.
function alts.on_alert(player, to, from, text)
    if to ~= '*' and to:lower() ~= player.name:lower() then return end
    windower.add_to_chat(167, ('[Vanguard] %s: %s'):format(from, text))
    if S.alerts.sound and S.alerts.sound ~= '' and windower.play_sound then
        pcall(windower.play_sound, S.alerts.sound)
    end
end

------------------------------------------------------------------------
-- Mount sync
------------------------------------------------------------------------
local was_mounted, last_bcast = nil, -100

-- Every character tells the others when it mounts / dismounts (and repeats it while mounted).
function alts.broadcast_mount(player)
    if not S.alts.mount then return end
    local m = has_buff(player.buffs, BUFF_MOUNTED)
    if m ~= was_mounted or (m and clock() - last_bcast > 10) then
        if was_mounted ~= nil or m then
            windower.send_ipc_message(('vg_mount %s %s'):format(player.name, m and 'on' or 'off'))
        end
        was_mounted, last_bcast = m, clock()
    end
end

function alts.on_mount(player, from, onoff)
    if S.leader == '' or from:lower() ~= S.leader:lower() then return end
    state.leader_mounted = (onoff == 'on')
    if onoff == 'off' then state.want_dismount = true end
end

-- On the alt: follow the leader's mount state (only when idle).
function alts.mount_sync(player)
    if not S.alts.mount or S.leader == '' then return false end
    local mounted = has_buff(player.buffs, BUFF_MOUNTED)
    if state.leader_mounted and not mounted and player.status == 0 and not h.party_engaged(player) then
        if h.recently('mount', 8) then return false end
        h.mark('mount')
        windower.send_command(('input /mount "%s"'):format(S.mount.name))
        h.log('Mounting (' .. S.mount.name .. ') with ' .. S.leader)
        return true
    end
    if state.want_dismount then
        if not mounted then state.want_dismount = false return false end
        if h.recently('dismount', 5) then return false end
        h.mark('dismount')
        windower.send_command('input /dismount')
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Food & Reraise upkeep (between fights)
------------------------------------------------------------------------
local item_ids = {}
local function item_by_name(name)
    local key = name:lower()
    if item_ids[key] == nil then
        item_ids[key] = false
        for id, it in pairs(res.items) do
            if type(it) == 'table' and ((it.en or ''):lower() == key or (it.enl or ''):lower() == key) then item_ids[key] = id break end
        end
    end
    return item_ids[key] or nil
end

local function in_inventory(id)
    local inv = windower.ffxi.get_items(0)
    for _, it in ipairs(inv or {}) do
        if type(it) == 'table' and it.id == id and (it.status or 0) == 0 then return true end
    end
    return false
end

local function use_item(name, why)
    windower.send_command(('input /item "%s" <me>'):format(name))
    state.busy_until = clock() + 4
    h.log(('%s (%s)'):format(name, why))
    return true
end

local RERAISE_SPELLS = { 'Reraise IV', 'Reraise III', 'Reraise II', 'Reraise' }

function alts.upkeep(player)
    if not S.alts.upkeep or player.status ~= 0 or h.party_engaged(player) then return false end
    local food = S.upkeep.food or ''
    if food ~= '' and not has_buff(player.buffs, BUFF_FOOD) and not h.recently('food', 30) then
        h.mark('food')
        local id = item_by_name(food)
        if id and in_inventory(id) then return use_item(res.items[id].en, 'food wore off') end
        if not h.recently('food_missing', 600) then h.mark('food_missing') h.log('No ' .. food .. ' in the inventory for food upkeep') end
    end
    local rr = S.upkeep.reraise or ''
    if rr ~= '' and rr ~= 'off' and not has_buff(player.buffs, BUFF_REraise) and not h.recently('reraise', 30) then
        h.mark('reraise')
        local spells = (rr:lower() == 'auto') and RERAISE_SPELLS or { rr }
        for _, name in ipairs(spells) do
            if h.try_cast(name, '<me>', 'Reraise upkeep', player) then return true end
        end
        if rr:lower() ~= 'auto' then
            local id = item_by_name(rr)
            if id and in_inventory(id) then return use_item(res.items[id].en, 'Reraise upkeep') end
        end
    end
    return false
end

function alts.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return alts
