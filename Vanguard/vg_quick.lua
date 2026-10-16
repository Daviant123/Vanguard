--[[
Vanguard: quick buttons (series 2 round 2, 2026-10-15). ISBoxer, the best-known paid multiboxing suite, gives
multiboxers click bars: buttons that make one chosen character do one chosen thing without switching to its window.
Vanguard Control builds them from menus (character, action, target); this module tells the app what each
character can use and carries out a button press.

  known(player)   spells it can cast now, its job abilities, weapon skills and usable items in the inventory
  //vg act <ma|ja|ws|item|attack|follow|stop> <bt|t|me|leader|Name> [name]
                  the panel's button press: a normal game command (/ma, /ja, /ws, /item, /attack, /follow)
]]

local util = require('vg_util')
local res = require('resources')

local quick = {}
local S, state, h

-- Lists for the button builder (only what this character can use right now).
function quick.known(player)
    local out = { spells = {}, abilities = {}, ws = {}, items = {} }
    local seen = {}
    for _, sp in pairs(res.spells) do
        -- (Trust spells have their own module, so they aren't offered as buttons)
        if sp.en and sp.type ~= 'Trust' and not seen[sp.en] and util.can_cast(sp, player) then seen[sp.en] = true out.spells[#out.spells + 1] = sp.en end
    end
    local ab = windower.ffxi.get_abilities() or {}
    for _, id in pairs(ab.job_abilities or {}) do
        local ja = res.job_abilities[id]
        if ja and ja.en and ja.type ~= 'Monster' then out.abilities[#out.abilities + 1] = ja.en end
    end
    out.wsprops = {}                                   -- skillchain properties, for the app's Skillchain builder
    for _, id in pairs(ab.weapon_skills or {}) do
        local ws = res.weapon_skills[id]
        if ws and ws.en then
            out.ws[#out.ws + 1] = ws.en
            local props = {}
            for _, k in ipairs({ 'skillchain_a', 'skillchain_b', 'skillchain_c' }) do
                if ws[k] and ws[k] ~= '' then props[#props + 1] = ws[k] end
            end
            out.wsprops[ws.en] = props
        end
    end
    local inv = (windower.ffxi.get_items() or {}).inventory
    seen = {}
    out.food, out.reraise, out.mounts = {}, {}, {}
    for _, it in ipairs(type(inv) == 'table' and inv or {}) do
        local item = type(it) == 'table' and it.id and res.items[it.id]
        if item and item.category == 'Usable' and not seen[item.en] then
            seen[item.en] = true
            out.items[#out.items + 1] = item.en
            if item.type == 1 then out.food[#out.food + 1] = item.en end                    -- food
            if item.en:find('Reraise') then out.reraise[#out.reraise + 1] = item.en end      -- Instant Reraise, ...
        end
    end
    -- (series 2 round 10) Reraise spells it can cast, and the mounts it owns, for the app's upkeep menus
    for _, n in ipairs({ 'Reraise IV', 'Reraise III', 'Reraise II', 'Reraise' }) do
        local sp = util.spell(n)
        if sp and util.can_cast(sp, player) then table.insert(out.reraise, 1, n) end
    end
    local owned = {}
    for _, id in pairs((windower.ffxi.get_key_items and windower.ffxi.get_key_items()) or {}) do
        local ki = res.key_items[id]
        if ki and ki.en then owned[ki.en:lower()] = true end
    end
    for _, m in pairs(res.mounts or {}) do
        if m.en and owned[('\226\153\170' .. m.en .. ' companion'):lower()] then out.mounts[#out.mounts + 1] = m.en end   -- key item "♪Raptor companion"
    end
    for k, t in pairs(out) do if k ~= 'wsprops' then table.sort(t) end end
    out.warp = require('vg_warp').way(player) or ''      -- (series 3 round 6) its way home, for the app's Go home box
    return out
end

local TARGET = { bt = '<bt>', t = '<t>', me = '<me>' }

-- //vg act <kind> <target> [name...]   Returns the game command it typed, or nil and why.
function quick.act(player, kind, target, name)
    kind, target = (kind or ''):lower(), target or ''
    local tgt = TARGET[target:lower()]
    if not tgt then
        if target:lower() == 'leader' then
            tgt = (S.leader ~= '' and S.leader:lower() ~= player.name:lower()) and S.leader or '<me>'
        elseif target:match('^%a+$') then
            tgt = target                                  -- a party member's name
        else
            return nil, 'bad target'
        end
    end
    local cmd
    if kind == 'ma' then
        local sp = util.spell(name)
        if not sp then return nil, 'unknown spell' end
        cmd = ('input /ma "%s" %s'):format(sp.en, tgt)
    elseif kind == 'ja' then
        local ja = util.ability(name)
        if not ja then return nil, 'unknown ability' end
        cmd = ('input /ja "%s" %s'):format(ja.en, tgt)
    elseif kind == 'ws' then
        local ws = util.wskill(name)
        if not ws then return nil, 'unknown weapon skill' end
        cmd = ('input /ws "%s" %s'):format(ws.en, tgt == '<me>' and '<t>' or tgt)
    elseif kind == 'item' then
        local found
        for _, it in pairs(res.items) do if it.en and name and it.en:lower() == name:lower() then found = it.en break end end
        if not found then return nil, 'unknown item' end
        cmd = ('input /item "%s" %s'):format(found, tgt)
    elseif kind == 'attack' then
        cmd = 'input /attack ' .. (tgt == '<me>' and '<bt>' or tgt)
    elseif kind == 'follow' then
        cmd = 'input /follow ' .. (tgt == '<me>' and '<p0>' or tgt)
    elseif kind == 'stop' then
        cmd = 'input /attackoff'
    else
        return nil, 'unknown action'
    end
    windower.send_command(cmd)
    state.busy_until = math.max(state.busy_until or 0, os.clock() + 2)   -- don't step on it straight away
    return cmd
end

------------------------------------------------------------------------
-- Hotkeys for quick buttons (series 2 round 6; ISBoxer's key maps): pressed in this game window, they make the
-- chosen character act. Kept in settings.hotkeys ("^1=Name|ma|me|Cure IV;!2=*|item|me|Echo Drops"), bound with
-- Windower's own bind on load. Ctrl / Alt + 1-0 only, so they never clash with the game's keys or //vg keys (Ctrl+F1-F7).
------------------------------------------------------------------------
quick.KEYS = {}
for _, mod in ipairs({ '^', '!' }) do for d = 0, 9 do quick.KEYS[mod .. d] = true end end

local function hk_map()
    local map, order = {}, {}
    for _, entry in ipairs(util.split(S.hotkeys or '', ';')) do
        local key, who, kind, target, name = entry:match('^([%^!]%d)=([^|]*)|([^|]*)|([^|]*)|(.*)$')
        if key and quick.KEYS[key] then
            if not map[key] then order[#order + 1] = key end
            map[key] = { who = who, kind = kind, target = target, name = name }
        end
    end
    return map, order
end
quick.hk_map = hk_map

local function hk_save(map, order)
    local parts = {}
    for _, k in ipairs(order) do
        local m = map[k]
        if m then parts[#parts + 1] = ('%s=%s|%s|%s|%s'):format(k, m.who, m.kind, m.target, m.name or '') end
    end
    S.hotkeys = table.concat(parts, ';')
end

function quick.hk_set(key, who, kind, target, name)
    if not quick.KEYS[key or ''] or not (who or ''):match('^[%a*]+$') or not (target or ''):match('^%a+$')
        or not ({ ma = 1, ja = 1, ws = 1, item = 1, attack = 1, follow = 1, stop = 1 })[kind or ''] then return false end
    if name and name:find('[;|]') then return false end
    local map, order = hk_map()
    if not map[key] then order[#order + 1] = key end
    map[key] = { who = who, kind = kind, target = target, name = name or '' }
    hk_save(map, order)
    windower.send_command(('bind %s vg hk %s'):format(key, key))
    return true
end

function quick.hk_clear(key)
    local map, order = hk_map()
    if not map[key or ''] then return false end
    map[key] = nil
    hk_save(map, order)
    windower.send_command('unbind ' .. key)
    return true
end

function quick.hk_bind_all(on)
    local _, order = hk_map()
    for _, k in ipairs(order) do
        windower.send_command(on and ('bind %s vg hk %s'):format(k, k) or ('unbind ' .. k))
    end
end

-- The key was pressed here: this character acts, or the order goes to the one it's for (or everyone).
function quick.hk_press(player, key)
    local m = hk_map()[key or '']
    if not m then return false end
    local cmd = ('act %s %s %s'):format(m.kind, m.target, m.name or ''):gsub('%s+$', '')
    if m.who == '*' then
        windower.send_ipc_message('vg_all ' .. cmd)
        quick.act(player, m.kind, m.target, m.name)
    elseif m.who:lower() == player.name:lower() then
        quick.act(player, m.kind, m.target, m.name)
    else
        windower.send_ipc_message(('vg_to %s %s'):format(m.who, cmd))
    end
    return true
end

------------------------------------------------------------------------
-- Mob lists by clicking (series 2 round 7; MMOMinion's grind whitelist / blacklist, filled by picking mobs, not
-- typing): what's around this character for the app, and adding / removing names on the farm lists.
------------------------------------------------------------------------
function quick.nearby(range)
    range = range or 50
    local by, me = {}, windower.ffxi.get_mob_by_target('me')
    local party = {}
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        if p[k] and p[k].mob and p[k].mob.id then party[p[k].mob.id] = true end
    end
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if type(m) == 'table' and m.is_npc and m.spawn_type == 16 and m.name and m.name ~= '' and (m.hpp or 0) > 0
            and m.valid_target ~= false and util.dist(m) <= range then
            local e = by[m.name] or { n = m.name, c = 0, d = 999, mine = 0, others = 0 }
            by[m.name] = e
            e.c = e.c + 1
            e.d = math.min(e.d, math.floor(util.dist(m) + 0.5))
            if m.claim_id and m.claim_id ~= 0 then
                if party[m.claim_id] then e.mine = e.mine + 1 else e.others = e.others + 1 end
            end
        end
    end
    local out = {}
    for _, e in pairs(by) do out[#out + 1] = e end
    table.sort(out, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.n < b.n end)
    return out
end

-- //vg farmlist add|remove targets|ignore <mob name>   |   //vg farmlist clear targets|ignore
function quick.farmlist(sub, which, name)
    if which ~= 'targets' and which ~= 'ignore' then return false end
    if sub == 'clear' then S.farm[which] = '' return true end
    name = util.trim(name or '')
    if name == '' or name:find(',') then return false end
    local out = {}
    for _, n in ipairs(util.split(S.farm[which] or '', ',')) do
        if n:lower() ~= name:lower() then out[#out + 1] = n end
    end
    if sub == 'add' then
        out[#out + 1] = name
        -- a mob is on one list or the other, not both
        local other = which == 'targets' and 'ignore' or 'targets'
        local keep = {}
        for _, n in ipairs(util.split(S.farm[other] or '', ',')) do if n:lower() ~= name:lower() then keep[#keep + 1] = n end end
        S.farm[other] = table.concat(keep, ',')
    elseif sub ~= 'remove' then
        return false
    end
    S.farm[which] = table.concat(out, ',')
    return true
end

function quick.farm_value(which) return S.farm[which] end

function quick.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return quick
