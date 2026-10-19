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

-- Is a shield in the off hand? true / false, or nil when it can't be told (then it isn't held against anything).
function engine.has_shield()
    local eq = windower.ffxi.get_items('equipment')
    if type(eq) ~= 'table' or eq.sub == nil then return nil end
    if eq.sub == 0 then return false end
    local it = windower.ffxi.get_items(eq.sub_bag or 0, eq.sub)
    local r = it and it.id and it.id ~= 0 and require('resources').items[it.id]
    if not r then return nil end
    return (r.shield_size or 0) > 0
end

-- Actions the game refused ("That action requires a shield.", "Unable to use job ability."): paused (10 minutes for
-- a missing shield / pet / weapon, 1 minute for a plain "unable") instead of retried every few seconds (his real game: Shield Bash while dual-wielding, 2026-10-17)
local refused = {}          -- action id -> time it may be tried again
local last_used             -- { id, label, t } the action engine's last command

local REFUSED = { [199] = { 'it needs a shield', 600 }, [215] = { 'it needs a pet', 600 },
                  [216] = { 'no ranged weapon equipped', 600 }, [307] = { 'it needs a two-handed weapon', 600 },
                  [40] = { "it can't be used in this area", 600 },
                  [87] = { 'the game says it is unable to use it', 60 }, [88] = { 'the game says it is unable to use it', 60 } }

function engine.on_message(actor_id, message_id, me)
    local r = REFUSED[message_id]
    if not r or actor_id ~= me or not last_used or now() - last_used.t > 4 then return nil end
    refused[last_used.id] = now() + r[2]
    local l = last_used
    last_used = nil
    return ('%s paused for %s: %s'):format(l.label, r[2] >= 120 and (math.floor(r[2] / 60) .. ' minutes') or (r[2] .. ' seconds'), r[1])
end

function engine.refused(id) return refused[id] and now() < refused[id] end

function engine.available(action, player, ja_set)
    ja_set = ja_set or ability_set()
    if action.shield and engine.has_shield() == false then return false end
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
-- The job's actions in this profile's priority order (MMOMinion-style Skill Manager: top first). Actions the
-- profile hasn't placed keep the job's order after the placed ones.
function engine.ordered(job, profile)
    local list = jobs.actions_for(job)
    local order = profile and profile.order
    if not order or #order == 0 then return list end
    local rank = {}
    for i, id in ipairs(order) do rank[id] = i end
    local out = {}
    for i, a in ipairs(list) do out[i] = a end
    local base = {}
    for i, a in ipairs(list) do base[a.id] = i end
    table.sort(out, function(x, y)
        local rx, ry = rank[x.id] or (1000 + base[x.id]), rank[y.id] or (1000 + base[y.id])
        return rx < ry
    end)
    return out
end

-- Move an action: up | down | top | bottom, or reset the whole order.
function engine.move(job, profile, id, how)
    if how == 'reset' then profile.order = nil return true end
    local ids = {}
    for _, a in ipairs(engine.ordered(job, profile)) do ids[#ids + 1] = a.id end
    local at
    for i, x in ipairs(ids) do if x == id then at = i end end
    if not at then return false end
    local to = ({ up = at - 1, down = at + 1, top = 1, bottom = #ids })[how]
    if not to then return false end
    to = math.max(1, math.min(#ids, to))
    table.remove(ids, at)
    table.insert(ids, to, id)
    profile.order = ids
    return true
end

-- The action with this profile's threshold changes on top of the job's defaults.
function engine.effective(a, profile)
    local o = profile and profile.opts and profile.opts[a.id]
    if not o then return a end
    local t = {}
    for k, v in pairs(o) do t[k] = v end
    return setmetatable(t, { __index = a })
end

local LIMITS = { 'party_below', 'hpp_below', 'mpp_below', 'mpp_above', 'tp_min', 'tp_max', 'pet_hpp_below' }

-- All actions this character can use, with their on/off state and editable thresholds.
function engine.list(profile, player)
    local out = {}
    local ja_set = ability_set()
    for _, a in ipairs(engine.ordered(player.main_job, profile)) do
        if engine.available(a, player, ja_set) then
            local e = engine.effective(a, profile)
            local limits = {}
            for _, k in ipairs(LIMITS) do
                if a[k] ~= nil or e[k] ~= nil then limits[#limits + 1] = { k = k, v = e[k], d = a[k] } end
            end
            limits[#limits + 1] = { k = 'cooldown', v = e.cooldown or 5, d = a.cooldown or 5 }
            limits[#limits + 1] = { k = 'when', v = e.when, d = a.when }
            out[#out + 1] = { id = a.id, label = a.label, group = a.group, on = engine.enabled(a, profile), limits = limits }
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

-- Can pets be called in this zone? (res.zones' can_pet; unknown zones count as yes)
function engine.pets_allowed()
    local info = windower.ffxi.get_info()
    local z = info and info.zone and require('resources').zones[info.zone]
    if not z then return true end
    return z.can_pet == true
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
    if a.geo_next then                                            -- Blaze of Glory: only right before a Geo spell
        local g = ctx.settings.geo or {}
        local sp = (g.geo or '') ~= '' and util.spell(g.geo)
        if not ctx.settings.modules.geo or not sp or not util.spell_ready(sp, p) or ctx.silenced(p) then return false end
        if util.targets(sp, 'Enemy') then                       -- enemy bubbles always go on the mob
            local bt = ctx.battle_target()
            if not bt or util.dist(bt) > 21.5 then return false end     -- no mob, or out of casting range
        end
    end
    if a.pet_hpp_below then                                       -- e.g. Life Cycle only for a luopan running low
        local pet = windower.ffxi.get_mob_by_target('pet')
        if not pet or (pet.hpp or 100) >= a.pet_hpp_below then return false end
    end
    if a.pet then
        local pet = windower.ffxi.get_mob_by_target('pet')
        if a.pet == 'none' and pet then return false end
        -- calling a pet where pets aren't allowed (towns: the game's can_pet) was retried every few seconds - seen on
        -- his PUP in Aht Urhgan Whitegate, 2026-10-18
        if a.pet == 'none' and not engine.pets_allowed() then return false end
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
        last_used = { id = a.id, label = a.label, t = now() }
        ctx.mark('act:' .. a.id)
        if a.once and mob then ctx.state.action_once[a.id] = mob.id end
    end
    return done
end

-- filter(a) -> bool selects which actions this pass may run.
function engine.run(ctx, profile, filter)
    if not ctx.settings.modules.actions or not profile then return false end
    -- only what this job / sub job / level can use now: a toggle left on from another sub job (Warcry from /WAR while
    -- /DNC) would otherwise be tried, since an ability the character doesn't have has no recast and looks ready
    local ja_set = ability_set()
    for _, a in ipairs(engine.ordered(ctx.player.main_job, profile)) do
        -- Nightingale / Troubadour / Marcato belong to the songs while Songs is on (NiTro right before the songs, Marcato
        -- right before its song): used on their own they went off at random and the songs missed them (2026-10-18)
        local songs_own = a.songs_managed and ctx.settings.modules.songs and (ctx.settings.songs.list or '') ~= ''
        if not songs_own and (not filter or filter(a)) and engine.enabled(a, profile) and not engine.refused(a.id)
            and engine.available(a, ctx.player, ja_set) then
            if try(engine.effective(a, profile), ctx) then return true end
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
