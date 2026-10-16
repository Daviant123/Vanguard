--[[
Vanguard: warp home together (series 3 round 6). Multibox suites like ISBoxer send one key to every window so the
whole team leaves at once; Vanguard Control has a "Go home" box that tells every character to warp, and each one
picks the best way it has by itself:

  1. the Warp spell (Black Mage main or sub, 100 MP)
  2. an Instant Warp scroll in the inventory
  3. a Warp Ring (inventory or a Mog Wardrobe): GearSwap's ring1 is locked (gs disable ring1), the ring is put on
     (/equip), and the ring is used once it's ready (8 s after equipping); GearSwap is unlocked after the zone change,
     or after 25 s if nothing happened (the ring was still on its reuse timer)

  //vg warp        warp home now (normal game commands only: /ma, /item, /equip)
  known.warp       (vg_quick) the way it would use, shown in the app
Gear is only equipped, never moved between bags.
]]

local util = require('vg_util')
local res = require('resources')

local warp = {}
local S, state, h

local RING_READY = 10      -- seconds after equipping before the ring can be used (its 8 s delay + a little)
local GIVE_UP = 25         -- seconds after using it with no zone change: unlock GearSwap and say so

local function clock() return os.clock() end

local function has_item(name, bags)
    local all = windower.ffxi.get_items() or {}
    for _, bag in ipairs(bags) do
        local list = all[bag]
        if type(list) == 'table' then
            for _, it in ipairs(list) do
                local item = type(it) == 'table' and it.id and res.items[it.id]
                if item and item.en == name then return true end
            end
        end
    end
    return false
end

local ALL_BAGS = { 'inventory', 'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4', 'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8' }

-- The way home this character has right now: 'Warp' (spell), 'Instant Warp', 'Warp Ring' or nil.
function warp.way(player)
    local sp = util.spell('Warp')
    if sp and util.can_cast(sp, player) and ((player.vitals or {}).mp or 0) >= (sp.mp_cost or 100) then return 'Warp' end
    if has_item('Instant Warp', { 'inventory' }) then return 'Instant Warp' end
    if has_item('Warp Ring', ALL_BAGS) then return 'Warp Ring' end
    return nil
end

function warp.go(player)
    local way = warp.way(player)
    if not way then
        h.log('Warp: no way home (no Warp spell, Instant Warp or Warp Ring)')
        return nil
    end
    state.busy_until = math.max(state.busy_until or 0, clock() + 2)
    if way == 'Warp' then
        windower.send_command('input /ma "Warp" <me>')
    elseif way == 'Instant Warp' then
        windower.send_command('input /item "Instant Warp" <me>')
    else
        windower.send_command('gs disable ring1')
        windower.send_command('input /equip ring1 "Warp Ring"')
        state.warp = { use_at = clock() + RING_READY }
        state.busy_until = math.max(state.busy_until, clock() + RING_READY + 10)
    end
    h.log('Warp: going home (' .. way .. ')')
    return way
end

-- Called every tick: uses the ring when it's ready, gives up if nothing happened.
function warp.tick(player)
    local w = state.warp
    if not w then return end
    if w.use_at and clock() >= w.use_at then
        w.use_at, w.give_up_at = nil, clock() + GIVE_UP
        windower.send_command('input /item "Warp Ring" <me>')
    elseif w.give_up_at and clock() >= w.give_up_at then
        state.warp = nil
        windower.send_command('gs enable ring1')
        h.log('Warp: the Warp Ring did not work (still on its reuse timer?) - GearSwap unlocked')
    end
end

function warp.on_zone()
    if state.warp then
        state.warp = nil
        windower.send_command('gs enable ring1')
    end
end

function warp.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return warp
