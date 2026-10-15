--[[
Vanguard triggers: "if this, then that" rules.

Rule format (one per settings.triggers.tN entry):
    condition [and condition ...] -> command [| cooldown seconds]

Conditions:
    hpp<40   mpp<30   tp>=1000            your own HP%/MP%/TP (operators: < <= > >= ==)
    hpp:Name<50                            a party member's HP%
    party_hpp<50                           any party member below 50% HP
    mob_hpp<25                             battle target HP%
    buff:Haste      !buff:Haste            you have / don't have a buff
    engaged   idle   resting               your status
    mob:Name                               battle target name contains Name
    readies:Ability Name                   a mob started a TP move in the last 3s
    casts:Spell Name                       a mob started casting in the last 3s
    chat:some text                         a chat line containing the text in the last 5s

Cooldown: a number of seconds, or "once" = once per battle target (EasyFarm-style battle lists).

Examples:
    mob:Locus and engaged -> input /ja "Provoke" <t> | once
    hpp<35 and engaged -> input /ja "Sentinel" <me> | 60
    readies:Hurricane Wing -> input /ma "Stoneskin" <me> | 30
    mpp<25 and idle -> input /heal | 30
]]

local util = require('vg_util')

local triggers = {}

local recent = { readies = {}, casts = {}, chat = {} }
local fired = {}

local function now() return os.clock() end

function triggers.note_mob(kind, name, actor)
    recent[kind][#recent[kind] + 1] = { name = name:lower(), t = now() }
    if #recent[kind] > 20 then table.remove(recent[kind], 1) end
end

function triggers.note_chat(text)
    recent.chat[#recent.chat + 1] = { name = text:lower(), t = now() }
    if #recent.chat > 30 then table.remove(recent.chat, 1) end
end

local function seen(kind, text, window)
    text = text:lower()
    for i = #recent[kind], 1, -1 do
        local e = recent[kind][i]
        if now() - e.t > window then break end
        if (kind == 'chat' and e.name:find(text, 1, true)) or e.name == text then return true end
    end
    return false
end

local function compare(a, op, b)
    if op == '<' then return a < b
    elseif op == '<=' then return a <= b
    elseif op == '>' then return a > b
    elseif op == '>=' then return a >= b
    elseif op == '==' or op == '=' then return a == b end
    return false
end

local function party()
    local out = {}
    local p = windower.ffxi.get_party()
    if not p then return out end
    for _, k in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
        if p[k] and p[k].name then out[#out + 1] = p[k] end
    end
    return out
end

local function check(cond, player)
    cond = util.trim(cond)
    local lc = cond:lower()

    if lc == 'engaged' then return player.status == 1 end
    if lc == 'idle' then return player.status == 0 end
    if lc == 'resting' then return player.status == 33 end
    local mobname = cond:match('^[Mm]ob:(.+)$')
    if mobname then
        local bt = windower.ffxi.get_mob_by_target('bt') or windower.ffxi.get_mob_by_target('t')
        return bt ~= nil and bt.name:lower():find(util.trim(mobname):lower(), 1, true) ~= nil
    end

    local neg, buffname = cond:match('^(!?)buff:(.+)$')
    if buffname then
        local has = util.has_buff(player.buffs, util.buff_id(util.trim(buffname)))
        return (neg == '!') ~= has
    end

    local kind, text = cond:match('^(%a+):(.+)$')
    if kind == 'readies' or kind == 'casts' then return seen(kind, util.trim(text), 3) end
    if kind == 'chat' then return seen('chat', util.trim(text), 5) end

    local stat, who, op, num = cond:match('^([%a_]+):?([^<>=]*)%s*([<>=]+)%s*(%d+)$')
    if not stat then return false end
    stat, who, num = stat:lower(), util.trim(who), tonumber(num)

    if stat == 'party_hpp' then
        for _, m in ipairs(party()) do
            if m.hpp > 0 and compare(m.hpp, op, num) then return true end
        end
        return false
    elseif stat == 'mob_hpp' then
        local bt = windower.ffxi.get_mob_by_target('bt')
        return bt ~= nil and compare(bt.hpp, op, num)
    elseif who ~= '' then
        for _, m in ipairs(party()) do
            if m.name:lower() == who:lower() then
                return compare(m[stat] or 0, op, num)
            end
        end
        return false
    end

    local v = player.vitals
    if stat == 'hpp' then return compare(v.hpp, op, num) end
    if stat == 'mpp' then return compare(v.mpp, op, num) end
    if stat == 'tp' then return compare(v.tp, op, num) end
    return false
end

local function parse(rule)
    local conds, action = rule:match('^(.-)%s*%->%s*(.+)$')
    if not conds then return nil end
    local cmd, cd = action:match('^(.-)%s*|%s*(%w+)%s*$')
    cmd = cmd or action
    if cd == 'once' then return nil, nil, nil, true, conds, cmd end
    local list = {}
    for c in (conds .. ' and '):gmatch('(.-)%s+and%s+') do
        if util.trim(c) ~= '' then list[#list + 1] = c end
    end
    return list, util.trim(cmd), tonumber(cd) or 10
end

local function parse_rule(rule)
    local list, cmd, cd, once, conds, ocmd = parse(rule)
    if once then
        list = {}
        for c in (conds .. ' and '):gmatch('(.-)%s+and%s+') do
            if util.trim(c) ~= '' then list[#list + 1] = c end
        end
        return list, util.trim(ocmd), 5, true
    end
    return list, cmd, cd, false
end

local fired_on = {}   -- [rule key] = mob id it fired on (for "once")

-- Returns true if a trigger fired this tick.
function triggers.run(settings, player, state)
    for key, rule in pairs(settings.triggers) do
        if type(rule) == 'string' and rule ~= '' then
            local conds, cmd, cooldown, once = parse_rule(rule)
            local bt = windower.ffxi.get_mob_by_target('bt')
            local blocked = once and bt and fired_on[key] == bt.id
            if conds and #conds > 0 and not blocked and (not fired[key] or now() - fired[key] >= cooldown) then
                local ok = true
                for _, c in ipairs(conds) do
                    if not check(c, player) then ok = false break end
                end
                if ok then
                    fired[key] = now()
                    if once and bt then fired_on[key] = bt.id end
                    windower.send_command(cmd)
                    windower.add_to_chat(207, '[Vanguard] trigger ' .. key .. ': ' .. cmd)
                    return true
                end
            end
        end
    end
    return false
end

return triggers
