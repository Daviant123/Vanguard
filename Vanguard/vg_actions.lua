--[[
Vanguard action engine: runs the job abilities from vg_jobs.lua under their
conditions, and remembers Phantom Roll totals for the Double-Up logic.
]]

local util = require('vg_util')
local jobs = require('vg_jobs')

local engine = {}

local function now() return os.clock() end

local nuke_tiers = {' VI', ' V', ' IV', ' III', ' II', ''}

------------------------------------------------------------------------
-- Availability (what this character can use right now)
------------------------------------------------------------------------
local function ability_set()
    local set = {}
    local ab = windower.ffxi.get_abilities()
    if ab and ab.job_abilities then
        for _, id in pairs(ab.job_abilities) do set[id] = true end
    end
    return set
end

local function best_nuke(element, player, ready_only)
    for _, suffix in ipairs(nuke_tiers) do
        local spell = util.spell(element .. suffix)
        if spell and util.can_cast(spell, player)
            and (not ready_only or util.spell_ready(spell, player)) then
            return spell
        end
    end
    return nil
end

function engine.available(action, player, ja_set)
    ja_set = ja_set or ability_set()
    if action.kind == 'ja' or action.kind == 'roll' then
        local ja = util.ability(action.name)
        return ja ~= nil and ja_set[ja.id] == true
    elseif action.kind == 'ma' then
        return util.can_cast(util.spell(action.name), player)
    elseif action.kind == 'nuke' then
        for _, el in ipairs(action.name) do
            if best_nuke(el, player, false) then return true end
        end
        return false
    elseif action.kind == 'ra' then
        return true
    end
    return false
end

-- All actions this character can use, with their on/off state.
function engine.list(profile, player)
    local out = {}
    local ja_set = ability_set()
    for _, a in ipairs(jobs.actions_for(player.main_job)) do
        if engine.available(a, player, ja_set) then
            out[#out + 1] = { id = a.id, label = a.label, group = a.group, on = engine.enabled(a, profile) }
        end
    end
    return out
end

function engine.enabled(action, profile)
    local t = profile.toggles[action.id]
    if t ~= nil then return t end
    return jobs.default_on(action, profile.role)
end

------------------------------------------------------------------------
-- Conditions
------------------------------------------------------------------------
local function member_by_name(ctx, name)
    for _, m in ipairs(ctx.party_members(20)) do
        if m.name:lower() == name:lower() then return m end
    end
end

local function resolve_target(a, ctx)
    local p = ctx.player
    if a.target == '{leader}' then
        local leader = ctx.settings.leader
        if leader == '' or leader:lower() == p.name:lower() then return '<me>', p.buffs end
        local m = member_by_name(ctx, leader)
        if not m then return nil end
        return m.name, ctx.buffs_of(m, p)
    elseif a.target == 'lowest' then
        local worst
        for _, m in ipairs(ctx.party_members(20)) do
            if m.hpp > 0 and (not worst or m.hpp < worst.hpp) then worst = m end
        end
        if not worst then return nil end
        if worst.name == p.name then return '<me>', p.buffs end
        return worst.name, ctx.buffs_of(worst, p)
    elseif a.target == '<t>' then
        if p.status ~= 1 then return nil end
        local t = windower.ffxi.get_mob_by_target('t')
        if not t or t.hpp == 0 or util.dist(t) > 21 then return nil end
        return '<t>', nil, t
    elseif a.target == '<bt>' then
        local bt = ctx.battle_target()
        if not bt or util.dist(bt) > 21 then return nil end
        return '<bt>', nil, bt
    end
    return '<me>', p.buffs
end

local function lowest_party_hpp(ctx)
    local low = 101
    for _, m in ipairs(ctx.party_members(20)) do
        if m.hpp > 0 and m.hpp < low then low = m.hpp end
    end
    return low
end

local function buff_up(a, buffs)
    if not buffs then return false end
    if a.buff_ids then
        for _, id in ipairs(a.buff_ids) do
            if util.has_buff(buffs, id) then return true end
        end
        return false
    end
    if a.buff_any then
        for _, name in ipairs(a.buff_any) do
            if util.has_buff(buffs, util.buff_id(name)) then return true end
        end
        return false
    end
    local id
    if a.buff then
        id = util.buff_id(a.buff)
    elseif a.kind == 'ma' then
        local spell = util.spell(a.name)
        id = spell and spell.status
    elseif a.kind == 'roll' then
        id = util.buff_id(a.name)
    end
    return id ~= nil and util.has_buff(buffs, id)
end

local function conditions_ok(a, ctx)
    local p, v = ctx.player, ctx.player.vitals
    local w = a.when
    if w == 'engaged' and p.status ~= 1 then return false end
    if w == 'combat' and not ctx.party_engaged(p) then return false end
    if w == 'idle' and (p.status ~= 0 or ctx.party_engaged(p)) then return false end
    if a.hpp_below and v.hpp >= a.hpp_below then return false end
    if a.mpp_below and v.mpp >= a.mpp_below then return false end
    if a.mpp_above and v.mpp <= a.mpp_above then return false end
    if a.tp_min and v.tp < a.tp_min then return false end
    if a.tp_max and v.tp >= a.tp_max then return false end
    if a.party_below and lowest_party_hpp(ctx) >= a.party_below then return false end
    if a.no_pld and ctx.pld_in_party and ctx.pld_in_party(p) then return false end
    if a.pet then
        local pet = windower.ffxi.get_mob_by_target('pet')
        if a.pet == 'none' and pet then return false end
        if a.pet == 'present' and not pet then return false end
    end
    return true
end

------------------------------------------------------------------------
-- Execution
------------------------------------------------------------------------
local function try(a, ctx)
    local p = ctx.player
    if ctx.recently('act:' .. a.id, a.cooldown or 5) then return false end
    if not conditions_ok(a, ctx) then return false end

    local target, buffs, mob = resolve_target(a, ctx)
    if not target then return false end
    if a.once and mob and ctx.state.action_once[a.id] == mob.id then return false end
    if (a.buff or a.buff_any or a.kind == 'roll' or (a.kind == 'ma' and buffs)) and buff_up(a, buffs) then
        return false
    end

    local done = false
    if a.kind == 'roll' and ctx.roll_in_range and not ctx.roll_in_range(p) then
        ctx.roll_approach(p)                       -- rolls only reach party members close by
        return false
    end
    if a.kind == 'ja' or a.kind == 'roll' then
        if ctx.amnesia(p) then return false end
        local ja = util.ability(a.name)
        if not util.ability_ready(ja) then return false end
        done = ctx.use_ja(ja, target)
        if done then ctx.log(a.label) end
    elseif a.kind == 'ma' then
        if ctx.silenced(p) then return false end
        local spell = util.spell(a.name)
        if not util.spell_ready(spell, p) then return false end
        done = ctx.cast(spell, target, a.label)
    elseif a.kind == 'nuke' then
        if ctx.silenced(p) then return false end
        for _, el in ipairs(a.name) do
            local spell = best_nuke(el, p, true)
            if spell then done = ctx.cast(spell, target, 'free nuke') break end
        end
    elseif a.kind == 'ra' then
        windower.send_command('input /ra <t>')
        ctx.state.busy_until = now() + 2.5
        done = true
    end

    if done then
        ctx.mark('act:' .. a.id)
        if a.once and mob then ctx.state.action_once[a.id] = mob.id end
    end
    return done
end

-- filter(a) -> bool selects which actions this pass may run.
function engine.run(ctx, profile, filter)
    if not ctx.settings.modules.actions or not profile then return false end
    for _, a in ipairs(jobs.actions_for(ctx.player.main_job)) do
        if (not filter or filter(a)) and engine.enabled(a, profile) then
            if try(a, ctx) then return true end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Phantom Roll: remember the last roll and its total.
------------------------------------------------------------------------
function engine.note_roll(name, value)
    if name == 'Double-Up' then name = engine.current_roll end
    if not name then return end
    engine.current_roll = name
    engine.last_roll = { name = name, value = value, time = now() }
end

-- Double-Up decisions (lucky / 11 / Snake Eye / Fold / bust odds) live in vg_support.lua.

return engine
