--[[
Vanguard's cure brain (0.97.0, his request 2026-11-14: "the curing is lackluster, especially in comparison to some of the
other ffxi bots ... deeply research other cure bots ... and exponentially improve it").

What the others do (read 2026-11-14: HealBot by Lorand - HB_CureUtils.lua, lor_actor.lua; CurePlease - RESEARCH.md):
  - pick the Cure by how much it really heals (a potency table the player types in), not by fixed HP steps;
  - Curaga when 3+ hurt members stand within 10 yalms of one of them, aimed at the one that covers the most;
  - danger levels (60 / 40 / 20 %), players before trusts (HealBot ignores trusts unless told otherwise).
What his log showed (CharB WHM/SCH, 2026-11-14 08:30-09:00): Cure III / IV only (the tier list was her RDM's, shared
by every job: Cure V and VI off), no Curaga with 4-5 members hurt (they were under "cure at" but not under "Curaga at",
and the Curaga list was the RDM's too), trusts at 83 % cured before CharA at 57 %.

Here:
  - AUTO (heal.auto, the default): every Cure / Curaga this job can cast is a candidate; how much each heals is LEARNED
    from the game's own "recovers N HP" results, per job (settings.cure_learn), starting from HealBot's default table.
    The smallest one that covers the HP missing is used; a tier can be switched off per job (settings.cure_off).
  - manual (heal.auto false): the old HP steps (heal.tiers) and Curaga list (heal.curagas), as before.
  - triage: lowest HP% first, priority members count 25 points lower, trusts 10 higher and only under heal.trust_at.
  - Curaga: each hurt member is tried as the centre; the one with the most hurt members within 10 yalms wins
    (heal.curaga_count or more), tier by their average HP missing. Someone under 30 % who the Curaga would not reach
    gets a single cure first.
No packets are sent: it only reads results Windower already hands every addon.
]]

local cure = {}
local util = require('vg_util')
local S, state, h

-- HealBot's default potencies (data/cure_potency.lua): the starting guess until this character's own are learned
cure.DEFAULT = {
    ['Cure'] = 94, ['Cure II'] = 207, ['Cure III'] = 469, ['Cure IV'] = 880, ['Cure V'] = 1110, ['Cure VI'] = 1395,
    ['Curaga'] = 150, ['Curaga II'] = 313, ['Curaga III'] = 636, ['Curaga IV'] = 1125, ['Curaga V'] = 1510,
}
cure.CURES = { 'Cure', 'Cure II', 'Cure III', 'Cure IV', 'Cure V', 'Cure VI' }                 -- smallest first
cure.CURAGAS = { 'Curaga', 'Curaga II', 'Curaga III', 'Curaga IV', 'Curaga V' }
cure.CURAGA_RADIUS = 10
-- Blue Magic cures (0.99.2; a Blue Mage's own healing was never part of "Cure the party": his wipes of 2026-11-14 were
-- BLU + NIN + WAR with no healer). Starting guesses from BG Wiki's soft caps (read 2026-11-14), then learned like the rest.
-- Only spells that are SET count (vg_util.can_cast). Pollen and Restoral heal the caster only; Healing Breeze and
-- White Wind heal the party members within about 10 yalms of the CASTER (not of a target, like Curaga).
cure.BLU_SINGLE = { 'Wild Carrot', 'Magic Fruit', 'Plenilune Embrace' }
cure.BLU_SELF = { 'Pollen', 'Restoral' }
cure.BLU_AOE = { 'Healing Breeze', 'White Wind' }
cure.BLU_RADIUS = 9                                    -- (BG Wiki: 10'; one yalm of margin, people move during the cast)
for n, hp in pairs({ ['Pollen'] = 36, ['Wild Carrot'] = 150, ['Magic Fruit'] = 550, ['Plenilune Embrace'] = 650,
                     ['Restoral'] = 1040, ['Healing Breeze'] = 180, ['White Wind'] = 600 }) do cure.DEFAULT[n] = hp end
local SELF_ONLY, IS_AOE = {}, {}
for _, n in ipairs(cure.BLU_SELF) do SELF_ONLY[n] = true end
for _, n in ipairs(cure.CURAGAS) do IS_AOE[n] = true end
for _, n in ipairs(cure.BLU_AOE) do IS_AOE[n] = true end
cure.ALL = { cure.CURES, cure.CURAGAS, cure.BLU_SINGLE, cure.BLU_SELF, cure.BLU_AOE }
function cure.is_heal(name) return cure.DEFAULT[name] ~= nil end
function cure.is_aoe(name) return IS_AOE[name] == true end

local function job()
    local p = windower.ffxi.get_player()
    return p and p.main_job or '?'
end

------------------------------------------------------------------------
-- learned potencies, per job: "Cure IV=912;Cure V=1180"
------------------------------------------------------------------------
local samples = {}      -- [job][spell] = { last few uncapped amounts }
local learned = {}      -- [job][spell] = number
local function load_job(j)
    if learned[j] then return learned[j] end
    learned[j], samples[j] = {}, {}
    local raw = util.job_get(S.cure_learn, j)
    for name, n in tostring(type(raw) == 'string' and raw or ''):gmatch('([^=;]+)=(%d+)') do
        -- (a number far under the starting guess is a bad sample, not a weak cure - dropped; his CharB 2026-11-21 had
        -- "learned" Cure III 28, Cure IV 50, Cure VI 569 and so used Cure VI for a 17 % top-up)
        local d = cure.DEFAULT[name]
        if d and tonumber(n) >= d * cure.FLOOR then learned[j][name] = tonumber(n) end
    end
    return learned[j]
end

function cure.potency(name, j)
    local l = load_job(j or job())
    if l[name] then return l[name] end
    if name == 'White Wind' then                       -- BG Wiki: floor(max HP / 7) x 2, from the caster's max HP
        local p = windower.ffxi.get_player()
        local mx = p and p.vitals and p.vitals.max_hp or 0
        if mx > 0 then return math.floor(mx / 7) * 2 end
    end
    return cure.DEFAULT[name] or 0
end

local function persist(j)
    local parts = {}
    for _, list in ipairs(cure.ALL) do
        for _, n in ipairs(list) do if learned[j][n] then parts[#parts + 1] = n .. '=' .. learned[j][n] end end
    end
    util.job_set(S.cure_learn, j, table.concat(parts, ';'))
    state.cure_learn_dirty = true                    -- saved with the next settings save / at most once a minute
end

-- One of my cures landed for `amount` on a target that was missing `missing` HP (nil = unknown).
-- A heal that filled the target says only "at least this much": it can raise the number, never lower it.
cure.FLOOR = 0.5
function cure.learn(name, amount, missing)
    if not cure.DEFAULT[name] or not amount or amount <= 0 then return end
    local j = job()
    local l = load_job(j)
    -- how much the target was missing isn't known (a cure from another feature, a Curaga on someone who was full):
    -- the number may only say "at least this much", like a heal that filled the target up
    local capped = (not missing) or amount >= missing * 0.97
    -- far under the starting guess: not a real full-strength heal (the target was nearly full) - ignored
    if not capped and amount < cure.DEFAULT[name] * cure.FLOOR then return end
    local before = l[name]
    if capped then
        if amount > (l[name] or cure.DEFAULT[name]) then l[name] = amount end
    else
        samples[j][name] = samples[j][name] or {}
        local s = samples[j][name]
        s[#s + 1] = amount
        if #s > 5 then table.remove(s, 1) end
        local best = 0
        for _, v in ipairs(s) do if v > best then best = v end end
        l[name] = best                                -- the most it healed in the last 5 real (not filled-up) cures
    end
    if l[name] ~= before then persist(j) end
end

------------------------------------------------------------------------
-- which tiers may be used
------------------------------------------------------------------------
local function off_set()
    local out = {}
    local raw = util.job_get(S.cure_off, job())
    for n in tostring(type(raw) == 'string' and raw or ''):gmatch('[^,]+') do out[util.trim(n):lower()] = true end
    return out
end

function cure.is_off(name) return off_set()[name:lower()] == true end

function cure.set_off(name, off)
    local set, out = off_set(), {}
    set[name:lower()] = off and true or nil
    for _, list in ipairs(cure.ALL) do
        for _, n in ipairs(list) do if set[n:lower()] then out[#out + 1] = n end end
    end
    util.job_set(S.cure_off, job(), table.concat(out, ','))
end

-- the tiers of a family this character can cast right now (learned, job / level, MP, recast), smallest first
local function ready(list, player)
    local off, out = off_set(), {}
    for _, n in ipairs(list) do
        local sp = util.spell(n)
        if sp and not off[n:lower()] and util.spell_ready(sp, player) then out[#out + 1] = sp end
    end
    return out
end

local function sorted(list, player)
    local cands = ready(list or cure.CURES, player)
    table.sort(cands, function(a, b)                   -- (smallest heal first: the lists mix families now)
        local pa, pb = cure.potency(a.en), cure.potency(b.en)
        if pa ~= pb then return pa < pb end
        return a.id < b.id
    end)
    return cands
end

cure.COVER = 0.85
-- The smallest ready tier that covers the HP missing (85 % of it counts as covering); else the biggest ready one.
-- cover (1.3.0, audit 2.4): how much of the missing HP counts as covered (default 0.85; heal.priority_cover for
-- priority members: 1.0 or more = a bigger cure for the tank).
function cure.pick(missing, player, list, cover)
    local best
    cover = tonumber(cover) or cure.COVER
    for _, sp in ipairs(sorted(list, player)) do
        best = sp
        if cure.potency(sp.en) >= missing * cover then return sp end
    end
    return best
end

-- the ready tier right above `sp` in the same list (nil: sp is already the biggest ready one)
function cure.pick_up(sp, player, list)
    local cands = sorted(list, player)
    for i, c in ipairs(cands) do
        if c.id == sp.id then return cands[i + 1] end
    end
end

------------------------------------------------------------------------
-- predictive healing (1.3.0, audit 3.2; heal.predict, off by default)
-- A short HP% history per member (fed from the party HP updates 0x0DD / 0x0DF and from every heal pass). "Falling
-- fast" means HP keeps dropping in BOTH halves of the last heal.predict_window seconds: one big hit followed by nothing
-- (spiky damage) gives no bonus, a tank losing HP all the time (steady damage) does. The slower half is the rate used,
-- so a single spike never inflates it. Used by cure.plan only: the HP% expected to be lost before the cure lands
-- (rate x heal.predict_lead seconds, capped at heal.predict_cap points) moves that member up the order, and when the
-- chosen cure would land short of what he will be missing then, the next tier up is used (one tier at most).
------------------------------------------------------------------------
cure.hist = {}                                         -- [mob id or name] = { { t = clock, hpp = n }, ... } oldest first
local function window() return math.max(1, tonumber(S and S.heal.predict_window) or 3) end

function cure.observe(key, hpp, t)
    if key == nil or not hpp then return end
    t = t or os.clock()
    local hs = cure.hist[key]
    if not hs then hs = {} cure.hist[key] = hs end
    local last = hs[#hs]
    if last and t < last.t then hs = {} cure.hist[key] = hs last = nil end      -- (clock went back: start again)
    if last and t - last.t < 0.05 then last.hpp = hpp                            -- (same moment: packet + heal pass)
    else hs[#hs + 1] = { t = t, hpp = hpp } end
    -- keep the window, plus the newest sample older than it (the baseline the first change in the window starts from)
    local cut = t - window()
    while #hs > 2 and hs[2].t <= cut do table.remove(hs, 1) end
    while #hs > 60 do table.remove(hs, 1) end
end

-- HP% per second this member keeps losing (0 = not falling steadily, or not watched long enough)
function cure.fall_rate(key, t)
    local hs = key ~= nil and cure.hist[key]
    if not hs or #hs < 3 then return 0 end
    t = t or os.clock()
    local w = window()
    local start, mid = t - w, t - w / 2
    if hs[1].t > start + w * 0.1 then return 0 end   -- (history shorter than the window)
    local d1, d2 = 0, 0
    for i = 2, #hs do
        local a, b = hs[i - 1], hs[i]
        if b.t > start and b.t <= t and b.hpp < a.hpp and b.hpp > 0 then
            if b.t <= mid then d1 = d1 + (a.hpp - b.hpp) else d2 = d2 + (a.hpp - b.hpp) end
        end
    end
    return math.min(d1, d2) / (w / 2)
end

local function hkey(m) return (m.mob and m.mob.id) or m.id or m.name end
cure.hkey = hkey

------------------------------------------------------------------------
-- who, and with what
------------------------------------------------------------------------
local function max_hp(m) return (m.hpp or 0) > 0 and math.floor((m.hp or 0) * 100 / m.hpp) or (m.hp or 0) end
local function missing(m) return math.max(0, max_hp(m) - (m.hp or 0)) end
local function is_trust(m) return m.mob and m.mob.is_npc and m.mob.spawn_type == 14 or false end
local function gap(a, b)
    if not a.mob or not b.mob then return 999 end
    local dx, dy = (a.mob.x or 0) - (b.mob.x or 0), (a.mob.y or 0) - (b.mob.y or 0)
    return math.sqrt(dx * dx + dy * dy)
end
cure.missing, cure.is_trust = missing, is_trust

-- members: party members in casting range, not on the ignore list. priority: set of lower-case names.
-- being_cured(m): another healer's cure is on its way. Returns nil or { spell, target (member), why, curaga, covered }.
-- elsewhere(m) (optional, the team planner, vg_plan): another healer covers this member. He still counts towards a
-- Curaga / Healing Breeze (party-wide damage is one Curaga, not single cures from every healer), but a single cure only
-- goes to a member not covered elsewhere.
function cure.plan(members, player, priority, being_cured, elsewhere)
    priority = priority or {}
    local hurt = {}
    -- predictive healing (3.2): HP% expected to be lost before the cure lands; it never changes WHO is under the cure
    -- line, only the order among those who are and (below) the tier
    local predict, t = S.heal.predict == true, os.clock()
    local lead = math.max(0, tonumber(S.heal.predict_lead) or 2)
    local cap = math.max(0, tonumber(S.heal.predict_cap) or 20)
    for _, m in ipairs(members) do
        if (m.hpp or 0) > 0 then
            local prio, trust = priority[m.name:lower()] == true, is_trust(m)
            local limit = prio and S.heal.priority_at or S.heal.cure_at
            if trust then limit = math.min(limit, tonumber(S.heal.trust_at) or 60) end
            -- an alliance member (another party): under heal.alliance_at, and after my own party at about the same HP
            if m.alliance and not prio then limit = math.min(limit, tonumber(S.heal.alliance_at) or 60) end
            if m.hpp < limit and not (being_cured and being_cured(m)) then
                local fall = 0
                if predict then fall = math.min(cap, m.hpp - 1, cure.fall_rate(hkey(m), t) * lead) end
                fall = math.max(0, fall)
                hurt[#hurt + 1] = { m = m, score = m.hpp - (prio and 25 or 0) + (trust and 10 or 0) + (m.alliance and 10 or 0) - fall,
                                    missing = missing(m), prio = prio, fall = fall }
            end
        end
    end
    if #hurt == 0 then return nil end
    table.sort(hurt, function(a, b) if a.score ~= b.score then return a.score < b.score end return a.m.name < b.m.name end)
    local worst = hurt[1]
    -- the worst-off member that is mine to single-cure (nil: everyone hurt is covered by another healer)
    local mine = worst
    if elsewhere then
        mine = nil
        for _, x in ipairs(hurt) do if not elsewhere(x.m) then mine = x break end end
    end

    -- Curaga: the centre that reaches the most hurt members
    local need = tonumber(S.heal.curaga_count) or 3
    local inside = {}                                    -- (Curaga only reaches the party: watched outsiders don't count)
    for _, x in ipairs(hurt) do if not x.m.outsider then inside[#inside + 1] = x end end
    if S.heal.curaga and #inside >= need and mine then   -- (mine nil: all of them are another healer's)
        local best
        -- heal.curaga_on (1.3.0, audit 2.5; '' = off): a fixed Curaga centre (a member who stands in the middle, e.g.
        -- the tank). Who wins: that member, when he is in range and his Curaga reaches heal.curaga_count hurt members;
        -- otherwise the usual search below (the centre that reaches the most). He need not be hurt himself.
        local fixed = type(S.heal.curaga_on) == 'string' and util.trim(S.heal.curaga_on):lower() or ''   -- (settings.xml can hand back {} for '')
        if fixed ~= '' then
            for _, cm in ipairs(members) do
                if cm.name:lower() == fixed and not cm.outsider and (cm.hpp or 0) > 0 then
                    local cover, total, has_worst = {}, 0, false
                    for _, o in ipairs(inside) do
                        if o.m == cm or gap(cm, o.m) <= cure.CURAGA_RADIUS then
                            cover[#cover + 1] = o
                            total = total + o.missing
                            if o == worst then has_worst = true end
                        end
                    end
                    -- (someone under 30 % this Curaga would miss: the usual search, which may find one that reaches him)
                    if #cover >= need and (has_worst or worst.m.hpp >= 30) then
                        best = { c = { m = cm }, cover = cover, total = total, has_worst = has_worst, fixed = true }
                    end
                    break
                end
            end
        end
        for _, c in ipairs(best and {} or inside) do
            local cover, total, has_worst = {}, 0, false
            for _, o in ipairs(inside) do
                if o == c or gap(c.m, o.m) <= cure.CURAGA_RADIUS then
                    cover[#cover + 1] = o
                    total = total + o.missing
                    if o == worst then has_worst = true end
                end
            end
            if #cover >= need and (not best or #cover > #best.cover or (#cover == #best.cover and total > best.total)) then
                best = { c = c, cover = cover, total = total, has_worst = has_worst }
            end
        end
        -- (someone in real danger the Curaga would not reach: a single cure for them first)
        if best and (best.has_worst or worst.m.hpp >= 30) then
            local sp = cure.pick(best.total / #best.cover, player, cure.CURAGAS)
            if sp then
                return { spell = sp, target = best.c.m, curaga = true, covered = #best.cover,
                         why = ('%d members hurt%s'):format(#best.cover, best.fixed and (' around ' .. best.c.m.name) or '') }
            end
        end
        -- no Curaga to cast: a Blue Mage's Healing Breeze / White Wind, which heal around the CASTER
        local me
        for _, m in ipairs(members) do if m.name == player.name then me = m end end
        if me and me.mob then
            local cover, total, has_worst = {}, 0, false
            for _, o in ipairs(inside) do
                if o.m == me or gap(me, o.m) <= cure.BLU_RADIUS then
                    cover[#cover + 1] = o
                    total = total + o.missing
                    if o == worst then has_worst = true end
                end
            end
            if #cover >= need and (has_worst or worst.m.hpp >= 30) then
                local sp = cure.pick(total / #cover, player, cure.BLU_AOE)
                if sp then
                    return { spell = sp, target = me, curaga = true, covered = #cover,
                             why = ('%d members hurt near me'):format(#cover) }
                end
            end
        end
    end

    if not mine then return nil end
    -- one member: the Cures, a Blue Mage's own (set) cures, and for myself Pollen / Restoral too
    local single = {}
    for _, list in ipairs({ cure.CURES, cure.BLU_SINGLE }) do for _, n in ipairs(list) do single[#single + 1] = n end end
    if mine.m.name == player.name then for _, n in ipairs(cure.BLU_SELF) do single[#single + 1] = n end end
    -- heal.priority_cover (2.4): a priority member's cure must cover this share of his missing HP (default 0.85 = like
    -- everyone; 1.0 or more = a bigger cure). Everyone else: 0.85.
    local cover = cure.COVER
    if mine.prio then cover = math.min(2, math.max(0.5, tonumber(S.heal.priority_cover) or cure.COVER)) end
    local sp = cure.pick(mine.missing, player, single, cover)
    local why = ('%s at %d%%'):format(mine.m.name, mine.m.hpp)
    -- predictive healing (3.2): he keeps falling, so by the time this cure lands he will be missing more. If the cure
    -- picked would then land short, the next tier up - one tier at most (the overheal cap), never past his max HP.
    if sp and mine.fall > 0 then
        local mx = max_hp(mine.m)
        local later = math.min(mx, mine.missing + mx * mine.fall / 100)
        if cure.potency(sp.en) < later * cover then
            local up = cure.pick_up(sp, player, single)
            if up then sp = up end
        end
        why = why .. (' (falling %d%%/s)'):format(math.floor(mine.fall / math.max(0.1, lead) + 0.5))
    end
    -- (nothing for one member, but he stands next to me: Healing Breeze / White Wind still reach him)
    if not sp and not mine.m.outsider and (mine.m.name == player.name or (function()
            for _, m in ipairs(members) do if m.name == player.name then return gap(m, mine.m) <= cure.BLU_RADIUS end end
        end)()) then
        sp = cure.pick(mine.missing, player, cure.BLU_AOE)
        if sp then
            return { spell = sp, target = { name = player.name }, curaga = true, covered = 1,
                     why = ('%s at %d%%'):format(mine.m.name, mine.m.hpp) }
        end
    end
    if not sp then return nil end
    return { spell = sp, target = mine.m, why = why, fall = mine.fall > 0 and mine.fall or nil }
end

-- for the app: what it has learned on this job
function cure.info()
    local out = { job = job(), auto = S.heal.auto ~= false, tiers = {} }
    local p = windower.ffxi.get_player()
    local blu = p and (p.main_job == 'BLU' or p.sub_job == 'BLU')
    for i, list in ipairs(cure.ALL) do
        for _, n in ipairs((i <= 2 or blu) and list or {}) do
            out.tiers[#out.tiers + 1] = { n = n, hp = cure.potency(n), learned = load_job(job())[n] ~= nil, off = cure.is_off(n) }
        end
    end
    return out
end

function cure.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return cure
