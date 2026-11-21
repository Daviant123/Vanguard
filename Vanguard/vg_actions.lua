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
    local r = it and it.id and it.id ~= 0 and require('vg_items').get(it.id)
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

-- an Unbridled spell (Unbridled Learning first) or a Scholar's Addendum spell (Addendum first) is listed / tried: prep
local UNBRIDLED_OK = { unbridled = true, addendum = true }

------------------------------------------------------------------------
-- "Use these abilities first" (his request 2026-11-09: Mighty Guard with Diffusion, and the same for other spells):
--   pre       job abilities used on me right before the action, "Diffusion/Chain Affinity" ('none' = none)
--   pre_mode  go (a prep that isn't ready is left out) | wait (the action waits for it)
--   ub        an Unbridled spell's opener: learning | wisdom | either (Learning, or Wisdom while Learning is on recast)
------------------------------------------------------------------------
function engine.pre_names(a)
    local out = {}
    if (a.pre or '') == '' or tostring(a.pre):lower() == 'none' then return out end
    for _, n in ipairs(util.split(tostring(a.pre), '/')) do
        n = n:match('^%s*(.-)%s*$')
        if n ~= '' and n:lower() ~= 'none' then out[#out + 1] = n end
    end
    return out
end

local function prep_ready(ja, p)
    if ja.recast_id == 231 then                         -- Scholar stratagems: a charge left is enough
        local ok, strat = pcall(require, 'vg_strat')
        if ok and strat.charges then return strat.charges(p) > 0 end
    end
    return util.ability_ready(ja)
end

local waitlog = {}
local function note_wait(ctx, key, text)
    if waitlog[key] and now() - waitlog[key] < 60 then return end
    waitlog[key] = now()
    ctx.log(text)
end

-- One prep step per call (a /ja, then the 1.5 s wait the next tick keeps). 'sent' = a /ja was sent; 'wait' = the
-- action waits (the abilities below it get their turn meanwhile); nil = nothing (more) first, the action may go now.
local function prep(a, ctx, ja_set)
    local p = ctx.player
    local amnesia = ctx.amnesia(p)                        -- no job abilities: as if none were ready
    local function send(ja, key)
        ctx.use_ja(ja, '<me>')
        ctx.mark(key)
        last_used = { id = 'prep:' .. ja.en, label = ja.en, t = now() }
        ctx.log(('%s before %s'):format(ja.en, a.label))
        return 'sent'
    end
    -- an Unbridled spell: Unbridled Learning / Wisdom has to be up (it can't go without it). Checked before anything else
    -- is used, so Diffusion isn't spent while Learning is still on recast.
    local opener
    local sp = a.kind == 'ma' and util.spell(a.name)
    if sp and util.unbridled(sp) and not util.unbridled_up(p.buffs) then
        -- just used it: wait for the buff to show (the spell is never sent without it - after an interrupted or used-up
        -- Learning the spell went again on its own, which the game refuses: seen in the panel test 2026-11-09)
        if ctx.recently('prep:unbridled', 8) then return 'wait' end
        local ul, uw = util.ability('Unbridled Learning'), util.ability('Unbridled Wisdom')
        local pick = a.ub or 'learning'
        if amnesia then
        elseif pick ~= 'wisdom' and ul and ja_set[ul.id] and util.ability_ready(ul) then opener = ul
        elseif pick ~= 'learning' and uw and ja_set[uw.id] and util.ability_ready(uw) then opener = uw end
        if not opener then
            note_wait(ctx, a.id .. 'ub', ('%s waits for %s'):format(a.label,
                pick == 'wisdom' and 'Unbridled Wisdom' or pick == 'either' and 'Unbridled Learning or Wisdom' or 'Unbridled Learning'))
            return 'wait'
        end
    end
    -- a Scholar's Addendum spell (Reraise on RDM/SCH, Poisona, Sleep...): Addendum: White / Black first, by itself
    -- (without it the game refuses the spell: CharB sent Reraise every 11 s for 15 minutes, 2026-11-12)
    if sp and not opener and util.ADDENDUM[sp.en] and not util.has_buff(p.buffs, util.ADDENDUM[sp.en])
        and not util.can_cast(sp, p) and util.can_cast(sp, p, { addendum = true }) then
        if ctx.recently('prep:addendum', 8) then return 'wait' end
        local ad = util.ability(util.ADDENDUM[sp.en] == 401 and 'Addendum: White' or 'Addendum: Black')
        if not amnesia and ad and ja_set[ad.id] and prep_ready(ad, p) then return send(ad, 'prep:addendum') end
        note_wait(ctx, a.id .. 'addendum', ('%s waits for %s'):format(a.label, ad and ad.en or 'Addendum'))
        return 'wait'
    end
    -- the abilities picked to go first, in their order; with "wait for it" all of them have to be ready before any is used
    local todo = {}
    for _, name in ipairs(engine.pre_names(a)) do
        local ja = util.ability(name)
        -- (an ability I don't have right now - another sub job - is left out)
        if ja and ja.en:lower() ~= tostring(a.name):lower() and ja_set[ja.id] then
            local up = (ja.status and util.has_buff(p.buffs, ja.status)) or ctx.recently('prep:' .. ja.en, 8)
            if not up then
                if not amnesia and not engine.refused('prep:' .. ja.en) and prep_ready(ja, p) then
                    todo[#todo + 1] = ja
                elseif a.pre_mode == 'wait' then
                    note_wait(ctx, a.id .. ja.en, ('%s waits for %s'):format(a.label, ja.en))
                    return 'wait'
                end
            end
        end
    end
    if todo[1] then return send(todo[1], 'prep:' .. todo[1].en) end
    if opener then return send(opener, 'prep:unbridled') end
    return nil
end
engine.prep = prep

-- What the game's own data says an ability needs (checked 2026-11-13/14 against BG Wiki: Saber Dance, Fan Dance,
-- Climactic Flourish): TP for dances, MP for blood pacts, no Waltz under Saber Dance, no Samba under Fan Dance, a
-- finishing move for a Flourish. Before, these were sent, refused by the game, and paused for a minute.
local FINISHING = { 381, 382, 383, 384, 385, 588 }
function engine.ja_rules_ok(ja, p)
    local v = p.vitals or {}
    if (ja.tp_cost or 0) > 0 and (v.tp or 0) < ja.tp_cost and not util.has_buff(p.buffs, util.buff_id('Trance')) then return false end
    if ja.prefix == '/pet' and (ja.mp_cost or 0) > (v.mp or 0) then return false end
    if ja.type == 'Waltz' and util.has_buff(p.buffs, 410) then return false end
    if ja.type == 'Samba' and util.has_buff(p.buffs, 411) then return false end
    if type(ja.type) == 'string' and ja.type:find('^Flourish') then
        local fm = false
        for _, id in ipairs(FINISHING) do if util.has_buff(p.buffs, id) then fm = true break end end
        if not fm then return false end
    end
    return true
end

function engine.available(action, player, ja_set)
    ja_set = ja_set or ability_set()
    if action.shield and engine.has_shield() == false then return false end
    if action.kind == 'ja' or action.kind == 'roll' then
        local ja = util.ability(action.name)
        return ja ~= nil and ja_set[ja.id] == true
    elseif action.kind == 'ma' then
        return util.can_cast(util.spell(action.name), player, UNBRIDLED_OK)
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
            local row = { id = a.id, label = a.label, group = a.group, on = engine.enabled(a, profile), limits = limits, custom = a.custom or nil }
            row.owned = engine.owner and engine.owner(a) or nil      -- "handled by the Buffs tab / EasyFarm's ... list"

            if a.kind ~= 'roll' then              -- "use these first": the app's First: chips
                row.pre = engine.pre_names(e)
                row.pre_d = engine.pre_names(a)
                row.pre_mode = e.pre_mode or 'go'
                local sp = a.kind == 'ma' and util.spell(a.name)
                if sp and util.unbridled(sp) then row.ub = e.ub or 'learning' end
            end
            out[#out + 1] = row
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
        -- (not on a KO'd leader: CharB sent Refresh III to CharA every 8 s after he died, 2026-11-12)
        if not m or (m.hpp or 1) <= 0 then return nil end
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
    if a.hpp_above and v.hpp <= a.hpp_above then return false end      -- (Berserk and the like: not while hurt)
    if a.need_buff and not util.has_buff(p.buffs, util.buff_id(a.need_buff)) then return false end   -- Cooldown: Overload
    if a.need_rune then                                                -- Vallation / Valiance / Pflug work off the runes up
        local rune = false
        for id = 523, 530 do if util.has_buff(p.buffs, id) then rune = true break end end
        if not rune then return false end
    end
    if a.avatar then                                                   -- a blood pact belongs to one avatar
        local pet = windower.ffxi.get_mob_by_target('pet')
        if not pet or pet.name ~= a.avatar then return false end
    end
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
local function try(a, ctx, ja_set)
    local p = ctx.player
    ja_set = ja_set or ability_set()
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
        if not engine.ja_rules_ok(ja, p) then return false end
        -- Crooked Cards right before the chosen roll (AutoCOR's option): a stronger roll
        if a.kind == 'roll' and ctx.crooked and ctx.crooked(a.name, p) then return true end
        if a.kind == 'ja' then local pre = prep(a, ctx, ja_set) if pre then return pre == 'sent' end end
        done = ctx.use_ja(ja, target)
        if done then ctx.log(a.label) end
    elseif a.kind == 'ma' then
        if ctx.silenced(p) then return false end
        local spell = util.spell(a.name)
        if not util.spell_ready(spell, p, UNBRIDLED_OK) then return false end
        local pre = prep(a, ctx, ja_set) if pre then return pre == 'sent' end
        done = ctx.cast(spell, target, a.label)
    elseif a.kind == 'nuke' then
        if ctx.silenced(p) then return false end
        for _, el in ipairs(a.name) do
            local spell = best_nuke(el, p, true)
            if spell then
                local pre = prep(a, ctx, ja_set) if pre then return pre == 'sent' end
                done = ctx.cast(spell, target, 'free nuke')
                break
            end
        end
    elseif a.kind == 'ra' then
        local pre = prep(a, ctx, ja_set) if pre then return pre == 'sent' end
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
        -- one owner per spell: the same spell ticked on the Buffs tab (same target) or switched on in one of EasyFarm's
        -- lists while it farms is left to that feature (his log 2026-11-10..14: Haste II on the leader, Reraise, Aquaveil,
        -- Auspice from both the Job tab and the Buffs tab; White Wind from the Job tab and EasyFarm's Healing list)
        local owned = engine.owner and engine.owner(a)
        if not songs_own and not owned and (not filter or filter(a)) and engine.enabled(a, profile) and not engine.refused(a.id)
            and engine.available(a, ctx.player, ja_set) then
            if try(engine.effective(a, profile), ctx, ja_set) then return true end
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
