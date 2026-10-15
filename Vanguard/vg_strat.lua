--[[
Vanguard: Scholar stratagems, for SCH main job and /SCH (user request 2026-10-15). From BG-wiki (Stratagems,
Accession, Perpetuance):

  Charges by Scholar level (main or sub): 10-29: 1 (4 min each), 30-49: 2 (2 min), 50-69: 3 (80 s), 70-89: 4 (60 s),
  90+: 5 (48 s; 33 s with the 550 Job Point gift). A WHM99/SCH49 has 2. They share recast 231 (time until all are
  back), so charges = floor((max * per - recast) / per).
  Light Arts (or Addendum: White) unlocks the white stratagems, Dark Arts (Addendum: Black) the black ones; each
  works on the NEXT spell of its kind and costs one charge:
    Penury -50% MP, Celerity -50% cast time, Accession (healing / enhancing white spell on the party within 10';
    works with Cure I-IV, Regen, Protect, Shell, -na, Erase, Refresh, Phalanx, Stoneskin, Blink, Aquaveil,
    Adloquium, Embrava, storms, Bar / En spells; NOT Raise, Reraise, Haste), Rapture (potency), Altruism (accuracy),
    Tranquility (less enmity), Perpetuance (main 87: enhancing duration x2, x2.5 with Arbatel / Savant bracers).
    Parsimony -50% MP, Alacrity -50% cast time, Manifestation (enfeeble on everything in range), Ebullience
    (potency), Focalization (accuracy), Equanimity (less enmity), Immanence (skillchains, vg_mages //vg chain).
  The game only offers the ones the character can use (job, level, sub job, merits): the ability list decides.

How Vanguard uses them: every spell goes through strat.before_cast. When a rule below matches, the stratagem is
used first and the spell is cast right after (state.strat_queue), so the module that wanted the spell doesn't have
to know. Rules (settings.strat, all editable in Vanguard Control's Stratagems tab):
  perpetuance / accession / penury / celerity / rapture / altruism / tranquility / parsimony / alacrity /
  manifestation / ebullience / focalization / equanimity   comma lists of spells
  accession_count  N party members within 10' missing the buff before Accession is spent on a buff
  accession_cure   N members hurt -> Accession on a Cure I-IV (a Scholar's Curaga); 0 = off
  penury_mp / parsimony_mp   any white / black spell when MP is under this % (0 = off)
  celerity_hp / rapture_hp   any cure on someone under this % HP (emergency; may use the reserve)
  reserve          charges kept back for emergencies (Celerity / Rapture emergencies and listed Raise spells)
  arts             auto (Light for healers / support, Dark for nukers) | light | dark | off: keep the Arts up
  jp_gift          550 Job Points: 33 s per charge
]]

local util = require('vg_util')

local strat = {}
local S, state, h

local function clock() return os.clock() end

local WHITE = { 'Penury', 'Celerity', 'Accession', 'Rapture', 'Altruism', 'Tranquility', 'Perpetuance' }
local BLACK = { 'Parsimony', 'Alacrity', 'Manifestation', 'Ebullience', 'Focalization', 'Equanimity', 'Immanence' }
local BUFF = { Penury = 360, Parsimony = 361, Celerity = 362, Alacrity = 363, Rapture = 364, Ebullience = 365,
               Accession = 366, Manifestation = 367, Altruism = 412, Focalization = 413, Tranquility = 414,
               Equanimity = 415, Perpetuance = 469, Immanence = 470 }
strat.BUFF = BUFF
local CURES = { Cure = true, ['Cure II'] = true, ['Cure III'] = true, ['Cure IV'] = true }
local RAISES = { Raise = true, ['Raise II'] = true, ['Raise III'] = true, Arise = true }

------------------------------------------------------------------------
-- Abilities and charges
------------------------------------------------------------------------
local function ja_set()
    local set = {}
    local ab = windower.ffxi.get_abilities()
    for _, id in pairs(ab and ab.job_abilities or {}) do set[id] = true end
    return set
end

function strat.has(name, set)
    local ja = util.ability(name)
    return ja and (set or ja_set())[ja.id] and ja or nil
end

-- The Scholar level that counts: main job, or the sub job's level.
function strat.level(player)
    if player.main_job == 'SCH' then return player.main_job_level or 0 end
    if player.sub_job == 'SCH' then return player.sub_job_level or 0 end
    return 0
end

function strat.max_charges(player)
    local lv = strat.level(player)
    if lv >= 90 then return 5 elseif lv >= 70 then return 4 elseif lv >= 50 then return 3
    elseif lv >= 30 then return 2 elseif lv >= 10 then return 1 end
    return 0
end

function strat.per_charge(player)
    local max = strat.max_charges(player)
    if max == 0 then return 240 end
    if player.main_job == 'SCH' and max == 5 and S.strat.jp_gift then return 33 end
    return 240 / max
end

function strat.charges(player)
    player = player or windower.ffxi.get_player()
    if not player then return 0 end
    local max = strat.max_charges(player)
    if max == 0 then return 0 end
    local per = strat.per_charge(player)
    local r = (windower.ffxi.get_ability_recasts() or {})[231] or 0
    return math.max(0, math.min(max, math.floor((max * per - r) / per + 1e-6)))
end

------------------------------------------------------------------------
-- The spells each stratagem can be ticked for (only what this character can cast)
------------------------------------------------------------------------
local SKILL = { [32] = 'Divine', [33] = 'Healing', [34] = 'Enhancing', [35] = 'Enfeebling', [36] = 'Elemental', [37] = 'Dark' }
local NO_ACCESSION = { Haste = true, ['Haste II'] = true, Raise = true, ['Raise II'] = true, ['Raise III'] = true, Arise = true,
                       Reraise = true, ['Reraise II'] = true, ['Reraise III'] = true, ['Reraise IV'] = true,
                       ['Cure V'] = true, ['Cure VI'] = true, ['Full Cure'] = true }

-- Accession works on single-target healing / enhancing white magic (not Raise, Reraise, Haste, Cure V / VI)
local function accession_ok(sp)
    if sp.type ~= 'WhiteMagic' or (sp.skill ~= 33 and sp.skill ~= 34) or NO_ACCESSION[sp.en] then return false end
    if sp.en:find('ga') and sp.en:find('^Cura') then return false end
    if sp.en:find('ra$') or sp.en:find('ra [IVX]+$') then return false end       -- Protectra, Barfira, ... are party already
    return true
end

-- Pools of spell names for the panel: white (with skill), enhancing, accession, black, enfeebling.
function strat.pools(player)
    local p = { white = {}, enhancing = {}, accession = {}, black = {}, enfeebling = {} }
    local seen = {}
    for _, sp in pairs(require('resources').spells) do
        if sp.en and not seen[sp.en] and (sp.type == 'WhiteMagic' or sp.type == 'BlackMagic') and util.can_cast(sp, player) then
            seen[sp.en] = true
            local item = { n = sp.en, s = SKILL[sp.skill] or 'Other' }
            if sp.type == 'WhiteMagic' then
                p.white[#p.white + 1] = item
                if sp.skill == 34 then p.enhancing[#p.enhancing + 1] = sp.en end
                if accession_ok(sp) then p.accession[#p.accession + 1] = sp.en end
            else
                p.black[#p.black + 1] = item
                if sp.skill == 35 then p.enfeebling[#p.enfeebling + 1] = sp.en end
            end
        end
    end
    local by = function(a, b) return (a.n or a) < (b.n or b) end
    for _, t in pairs(p) do table.sort(t, by) end
    return p
end

-- Lists that can be ticked from the panel (//vg stratspell <list> on|off|clear <spell>)
strat.LISTS = { perpetuance = true, accession = true, celerity = true, penury = true, rapture = true, altruism = true,
                tranquility = true, parsimony = true, alacrity = true, manifestation = true, ebullience = true,
                focalization = true, equanimity = true }

function strat.list(name) return S.strat[name] end

function strat.toggle(list, what, name)
    if not strat.LISTS[list or ''] then return false, 'unknown list' end
    if what == 'clear' then S.strat[list] = '' return true end
    local sp = name and util.spell(name)
    if not sp then return false, 'unknown spell' end
    local out = {}
    for _, n in ipairs(util.split(S.strat[list] or '', ',')) do
        if n:lower() ~= sp.en:lower() then out[#out + 1] = n end
    end
    if what == 'on' then out[#out + 1] = sp.en end
    S.strat[list] = table.concat(out, ',')
    return true
end

local function light(player) return util.has_buff(player.buffs, 358) or util.has_buff(player.buffs, 401) end
local function dark(player) return util.has_buff(player.buffs, 359) or util.has_buff(player.buffs, 402) end

-- What the panel shows: charges, the stratagems this character can use right now.
function strat.info(player)
    local set = ja_set()
    local avail = {}
    for _, n in ipairs(WHITE) do if strat.has(n, set) then avail[#avail + 1] = n end end
    for _, n in ipairs(BLACK) do if strat.has(n, set) then avail[#avail + 1] = n end end
    return { level = strat.level(player), max = strat.max_charges(player), per = strat.per_charge(player),
             charges = strat.charges(player), main = player.main_job == 'SCH', available = avail,
             arts = light(player) and 'light' or (dark(player) and 'dark' or 'none'),
             can_arts = strat.has('Light Arts', set) ~= nil,
             pools = strat.max_charges(player) > 0 and strat.pools(player) or nil }
end

------------------------------------------------------------------------
-- Rules
------------------------------------------------------------------------
local function in_list(list, name)
    for _, n in ipairs(util.split(list or '', ',')) do
        if n:lower() == name:lower() then return true end
    end
    return false
end

local function member(name)
    for _, m in ipairs(h.party_members(20)) do
        if m.name:lower() == tostring(name):lower() then return m end
    end
end

local function target_hpp(target, player)
    if target == '<me>' or target == player.name then return player.vitals.hpp end
    local m = member(target)
    return m and m.hpp or 100
end

-- Party members within 10' that don't have this buff (unknown buffs count as missing only for us).
local function missing_buff(spell, player)
    local n = 0
    for _, m in ipairs(h.party_members(10)) do
        local bl = h.buffs_of(m, player)
        if bl and m.hpp > 0 and (not spell.status or not util.has_buff(bl, spell.status)) then n = n + 1 end
    end
    return n
end

local function hurt_near(player)
    local n = 0
    for _, m in ipairs(h.party_members(10)) do
        if m.hpp > 0 and m.hpp < (tonumber(S.heal.cure_at) or 75) then n = n + 1 end
    end
    return n
end

-- Which stratagem (if any) this spell should get now. Returns name, emergency.
function strat.pick(spell, target, player, set)
    local C = S.strat
    local white, black = spell.type == 'WhiteMagic', spell.type == 'BlackMagic'
    local function ready(n) return not util.has_buff(player.buffs, BUFF[n]) and strat.has(n, set) end
    local mpp = player.vitals.mpp or 100
    if white and light(player) then
        local cure = CURES[spell.en] or spell.skill == 33 and spell.en:find('^Cure')
        -- emergencies first
        if (RAISES[spell.en] and in_list(C.celerity, spell.en)) and ready('Celerity') then return 'Celerity', true end
        if cure and (tonumber(C.celerity_hp) or 0) > 0 and target_hpp(target, player) < C.celerity_hp and ready('Celerity') then
            return 'Celerity', true
        end
        if cure and (tonumber(C.rapture_hp) or 0) > 0 and target_hpp(target, player) < C.rapture_hp and ready('Rapture') then
            return 'Rapture', true
        end
        -- Accession: a Scholar's Curaga, and buffs for the whole party
        if CURES[spell.en] and (tonumber(C.accession_cure) or 0) > 0 and hurt_near(player) >= C.accession_cure and ready('Accession') then
            return 'Accession'
        end
        if in_list(C.accession, spell.en) and missing_buff(spell, player) >= (tonumber(C.accession_count) or 3) and ready('Accession') then
            return 'Accession'
        end
        if spell.skill == 34 and in_list(C.perpetuance, spell.en) and ready('Perpetuance') then return 'Perpetuance' end
        if in_list(C.celerity, spell.en) and not RAISES[spell.en] and ready('Celerity') then return 'Celerity' end
        if (in_list(C.penury, spell.en) or ((tonumber(C.penury_mp) or 0) > 0 and mpp < C.penury_mp and (spell.mp_cost or 0) >= 20))
            and ready('Penury') then return 'Penury' end
        if in_list(C.rapture, spell.en) and ready('Rapture') then return 'Rapture' end
        if in_list(C.altruism, spell.en) and ready('Altruism') then return 'Altruism' end
        if in_list(C.tranquility, spell.en) and ready('Tranquility') then return 'Tranquility' end
    elseif black and dark(player) then
        if spell.skill == 35 and in_list(C.manifestation, spell.en) and ready('Manifestation') then return 'Manifestation' end
        if in_list(C.ebullience, spell.en) and ready('Ebullience') then return 'Ebullience' end
        if in_list(C.alacrity, spell.en) and ready('Alacrity') then return 'Alacrity' end
        if (in_list(C.parsimony, spell.en) or ((tonumber(C.parsimony_mp) or 0) > 0 and mpp < C.parsimony_mp and (spell.mp_cost or 0) >= 20))
            and ready('Parsimony') then return 'Parsimony' end
        if in_list(C.focalization, spell.en) and ready('Focalization') then return 'Focalization' end
        if in_list(C.equanimity, spell.en) and ready('Equanimity') then return 'Equanimity' end
    end
    return nil
end

-- Called by cast(): true = a stratagem was used first and the spell is queued to follow.
function strat.before_cast(spell, target, why)
    if not S.strat.enabled then return false end
    local player = windower.ffxi.get_player()
    if not player or strat.max_charges(player) == 0 or h.amnesia(player) then return false end
    local set = ja_set()
    local name, emergency = strat.pick(spell, target, player, set)
    if not name then return false end
    local reserve = emergency and 0 or (tonumber(S.strat.reserve) or 0)
    if strat.charges(player) <= reserve then return false end
    if h.recently('ja:' .. name .. ':<me>', 4) then return false end
    local ja = strat.has(name, set)
    h.log(('%s for %s%s'):format(name, spell.en, emergency and ' (emergency)' or ''))
    h.use_ja(ja, '<me>')
    state.strat_queue = { spell = spell, target = target, why = why, at = clock() }
    return true
end

-- Cast the spell that waited for its stratagem. Returns true when it acted.
function strat.run_queue()
    local q = state.strat_queue
    if not q then return false end
    if clock() - q.at > 8 then state.strat_queue = nil return false end
    state.strat_queue = nil
    return h.cast(q.spell, q.target, q.why)
end

------------------------------------------------------------------------
-- Keep Light / Dark Arts up (SCH main or sub)
------------------------------------------------------------------------
function strat.want_arts(player)
    local a = S.strat.arts or 'auto'
    if a == 'off' then return nil end
    if a == 'light' or a == 'dark' then return a end
    local role = state.profile and state.profile.role or ''
    if role == 'nuker' or player.main_job == 'BLM' then return 'dark' end
    return 'light'
end

function strat.arts(player)
    if strat.max_charges(player) == 0 or h.amnesia(player) then return false end
    local want = strat.want_arts(player)
    if not want or (want == 'light' and light(player)) or (want == 'dark' and dark(player)) then return false end
    local name = want == 'light' and 'Light Arts' or 'Dark Arts'
    local ja = strat.has(name)
    if not ja or not util.ability_ready(ja) or h.recently('ja:' .. name .. ':<me>', 5) then return false end
    h.log(name .. ' (stratagems)')
    return h.use_ja(ja, '<me>')
end

function strat.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return strat
