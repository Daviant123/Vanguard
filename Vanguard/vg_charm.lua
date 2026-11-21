--[[
Vanguard: sleep a charmed party member (0.99.5, his request 2026-11-21: "include an option to auto sleep charmed
people in the party ... let me choose which sleep and if that job has multiple sleeps i should be able to select
multiple and prioritize multiple").

A charmed player fights for the monster and attacks the party. Sleep holds them until the charm wears off (curing them
afterwards wakes them up: "Wake sleeping members" on the Healing tab).
  - who: party and alliance members within 20 yalms whose game data says charmed (the mob's own flag or the Charm
    status, ids 14 / 17), not already asleep, not just slept by one of us (shared with the other characters: vg_sleep);
  - with what: the sleeps ticked for THIS job, in his order (settings.charm_sleeps[job] = "Sleep II,Repose,..."):
    the first one that is ready (learned, set for Blue Magic, MP, recast). Nothing chosen yet = every sleep the job has,
    in the recommended order below. "-" = he unticked them all.
Only normal commands: /ma "<sleep>" <name>.
]]

local charm = {}
local util = require('vg_util')
local S, state, h

local function clock() return os.clock() end

-- the recommended order: strong single-target sleeps first, area sleeps last (they also put the monster to sleep)
charm.RECOMMENDED = { 'Sleep II', 'Repose', 'Foe Lullaby II', 'Sleep', 'Foe Lullaby', 'Dream Flower', 'Yawn',
                      'Soporific', 'Sheep Song', 'Sleepga II', 'Horde Lullaby II', 'Sleepga', 'Horde Lullaby' }
charm.AREA = { ['Sleepga'] = true, ['Sleepga II'] = true, ['Horde Lullaby'] = true, ['Horde Lullaby II'] = true,
               ['Dream Flower'] = true, ['Sheep Song'] = true, ['Yawn'] = true, ['Soporific'] = true }
-- Blue Magic area sleeps work around the CASTER (BG Wiki, read 2026-11-21): the charmed member has to stand this close
-- to me (Sheep Song / Soporific 6', Yawn / Dream Flower 10'; a little margin). Yawn is a gaze: he must face me.
charm.CASTER_REACH = { ['Sheep Song'] = 5.5, ['Soporific'] = 5.5, ['Yawn'] = 9.5, ['Dream Flower'] = 9.5 }
-- Scholar (main or support): Manifestation makes the next Black Magic enfeeble an area one (BG Wiki: SCH 40, a Dark
-- Arts stratagem, more MP and recast). Offered as its own entry, "Sleep II + Manifestation", to tick and order.
charm.MANIF = ' + Manifestation'
charm.MANIF_OK = { ['Sleep'] = true, ['Sleep II'] = true }
local function parse(entry)
    entry = util.trim(entry or '')
    local base = entry
    local m = entry:lower():find(charm.MANIF:lower(), 1, true)
    if m then base = util.trim(entry:sub(1, m - 1)) end
    local sp = util.spell(base)
    if not sp then return nil end
    if m and not charm.MANIF_OK[sp.en] then return nil end
    return sp, m ~= nil, sp.en .. (m and charm.MANIF or '')
end
charm.parse = parse
local function scholar(player) return player.main_job == 'SCH' or player.sub_job == 'SCH' end
local CHARM = { [14] = true, [17] = true }
local ASLEEP = { [2] = true, [19] = true }

local function job()
    local p = windower.ffxi.get_player()
    return p and p.main_job or '?'
end

-- every sleep this character can cast on its current jobs (Blue Magic: only while set)
function charm.available(player)
    local out = {}
    for _, n in ipairs(charm.RECOMMENDED) do
        local sp = util.spell(n)
        -- (a Scholar's Sleep / Sleep II count too: they need Dark Arts + Addendum: Black, which charm.tick uses first)
        if sp and util.can_cast(sp, player, { addendum = true }) then out[#out + 1] = sp.en end
    end
    -- the same Black Magic sleeps with Manifestation first (area), for a Scholar main or support who has it
    local mf = util.ability('Manifestation')
    if scholar(player) and mf and util.ability_known(mf) then
        for _, n in ipairs({ 'Sleep II', 'Sleep' }) do
            local sp = util.spell(n)
            if sp and util.can_cast(sp, player, { addendum = true }) then out[#out + 1] = sp.en .. charm.MANIF end
        end
    end
    return out
end

-- what he picked for this job, in his order (only those still castable); nil = never picked (use the recommended order)
function charm.chosen()
    local raw = util.job_get(S.charm_sleeps, job())
    if type(raw) ~= 'string' or raw == '' then return nil end
    if raw == '-' then return {} end
    local out = {}
    for _, n in ipairs(util.split(raw, ',')) do
        local sp, _, full = parse(n)
        if sp then out[#out + 1] = full end
    end
    return out
end

function charm.order(player)
    local avail, set = charm.available(player), {}
    for _, n in ipairs(avail) do set[n] = true end
    local picked = charm.chosen()
    if not picked then return avail end
    local out = {}
    for _, n in ipairs(picked) do if set[n] then out[#out + 1] = n end end
    return out
end

-- //vg charmsleep set A,B,C | none | reset
function charm.set(list)
    local v = list
    if list == 'none' then v = '-' elseif list == 'reset' then v = '' end
    if v ~= '-' and v ~= '' then
        local keep = {}
        for _, n in ipairs(util.split(list, ',')) do
            local sp, _, full = parse(n)
            if sp then keep[#keep + 1] = full end
        end
        v = #keep > 0 and table.concat(keep, ',') or '-'
    end
    util.job_set(S.charm_sleeps, job(), v)
end

local function charmed(m, bl)
    if m.charmed then return true end
    for _, id in ipairs(bl or {}) do if CHARM[id] then return true end end
    return false
end
local function asleep(bl)
    for _, id in ipairs(bl or {}) do if ASLEEP[id] then return true end end
    return false
end

-- one sleep on a charmed member, when one needs it; true when a spell went out (or is waiting to)
function charm.tick(player)
    if not S.charm.on or h.silenced(player) then return false end
    state.slept = state.slept or {}
    state.charm_seen = state.charm_seen or {}
    local p = windower.ffxi.get_party() or {}
    local order
    for _, k in ipairs(util.ALLIANCE_KEYS) do
        local pm = p[k]
        local mob = pm and pm.mob
        if k ~= 'p0' and mob and mob.id ~= player.id and (mob.hpp or pm.hpp or 0) > 0 and mob.valid_target ~= false then
            local bl = state.party_buffs and state.party_buffs[mob.id]
            if charmed(mob, bl) and not asleep(bl) and util.dist(mob) <= 20 then
                if not state.charm_seen[mob.id] or clock() - state.charm_seen[mob.id] > 60 then
                    state.charm_seen[mob.id] = clock()
                    h.log(pm.name .. ' is charmed!')
                end
                if (state.slept[mob.id] or 0) <= clock() then
                    order = order or charm.order(player)
                    if #order == 0 then
                        if not h.recently('charm:none', 60) then
                            h.mark('charm:none')
                            h.log(('%s is charmed, but no sleep is ticked for %s (Enfeebles tab)'):format(pm.name, player.main_job))
                        end
                        return false
                    end
                    for _, name in ipairs(order) do
                        local sp, manif = parse(name)
                        local reach = sp and charm.CASTER_REACH[sp.en]
                        if reach and util.dist(mob) > reach then sp = nil end      -- (around me: he is too far)
                        if sp and manif then
                            -- Manifestation first (Dark Arts up, a charge left); its buff on: the sleep goes out
                            if not util.spell_ready(sp, player, { addendum = true }) then sp = nil
                            elseif not util.has_buff(player.buffs, 367) then
                                local prep = charm.manifest_prep(player)
                                if prep then return true end
                                sp = nil                                           -- (can't now: the next one)
                            end
                        end
                        -- only through Scholar (WHM/SCH, SCH main): Dark Arts, then Addendum: Black, then the sleep
                        if sp and not util.can_cast(sp, player) and util.spell_ready(sp, player, { addendum = true }) then
                            local prep = charm.scholar_prep(player)
                            if prep ~= nil then return prep end
                        end
                        if sp and util.spell_ready(sp, player) then
                            -- (false: still stopping to stand still - tried again next pass)
                            if not h.cast(sp, pm.name, 'sleep ' .. pm.name .. ' (charmed)') then return false end
                            state.slept[mob.id] = clock() + 8                 -- cast: the result says how long
                            windower.send_ipc_message(('vg_sleep %d 8'):format(mob.id))
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Dark Arts, then Addendum: Black (a stratagem charge); true = an ability went out, false = it can't now, nil = both up
function charm.scholar_prep(player)
    if util.has_buff(player.buffs, 402) then return nil end                   -- Addendum: Black is up
    if h.recently('charm:prep', 3) then return true end                       -- (just used one: its buff is coming)
    if not (util.has_buff(player.buffs, 359)) then
        local da = util.ability('Dark Arts')
        if da and util.ability_ready(da) then h.mark('charm:prep') h.log('Dark Arts (to sleep a charmed member)') return h.use_ja(da, '<me>') end
        return false
    end
    local ad = util.ability('Addendum: Black')
    local ok, strat = pcall(require, 'vg_strat')
    local charges = ok and strat.charges and strat.charges(player) or 0
    if ad and util.ability_known(ad) and charges > 0 then
        h.mark('charm:prep') h.log('Addendum: Black (to sleep a charmed member)')
        return h.use_ja(ad, '<me>')
    end
    return false
end

-- Dark Arts, then Manifestation; true = an ability went out (or its buff is coming), false = it can't now
function charm.manifest_prep(player)
    if h.recently('charm:manif', 3) then return true end
    local mf = util.ability('Manifestation')
    local ok, strat = pcall(require, 'vg_strat')
    if not (mf and util.ability_known(mf) and ok and strat.charges and strat.charges(player) > 0) then return false end
    if not (util.has_buff(player.buffs, 359) or util.has_buff(player.buffs, 402)) then
        local da = util.ability('Dark Arts')
        if da and util.ability_ready(da) then h.mark('charm:manif') h.log('Dark Arts (for Manifestation)') return h.use_ja(da, '<me>') end
        return false
    end
    h.mark('charm:manif') h.log('Manifestation (area sleep on a charmed member)')
    return h.use_ja(mf, '<me>')
end

-- for the app
function charm.info(player)
    local picked = charm.chosen()
    return { on = S.charm.on == true, available = charm.available(player), order = charm.order(player),
             picked = picked ~= nil, job = job() }
end

function charm.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return charm
