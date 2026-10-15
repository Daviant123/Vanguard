--[[
Vanguard: White Mage, Red Mage and Scholar know-how from the community job guides (round 9, 2026-10-15).

  WHM / SCH  AoE status removal  When 2 or more party members have the same ailment, Divine Seal (WHM) or
                                 Accession (SCH, in Light Arts) first, so one -na clears everyone.
             Bar spells          //vg bar fire|ice|wind|earth|thunder|water [status] | off
                                 keeps the Bar-element up together with its matching Bar-status
                                 (Barfira + Baramnesra, Barblizzara + Barparalyzra, Baraera + Barsilencera,
                                 Barstonra + Barpetra, Barwatera + Barpoisonra; WHM casts the party -ra
                                 versions, RDM / SCH the self ones). Sent from the leader, every alt does it.
             Paladin in party    Protectra is skipped while a Paladin is in the party (Majesty is better).
  RDM        Saboteur timing     Saboteur right before the first Dia / Distract / Frazzle on a new mob.
             Stymie              when Frazzle or Distract was resisted, Stymie so the retry always lands.
  Anyone     Sleep extra mobs    //vg sleep on: a second mob attacking the party (not the one the leader is
  with sleep                     fighting) gets Sleep II / Sleep / Foe Lullaby / Sleepga; it re-sleeps
                                 when the mob wakes up (attacks again) and learns mobs sleep has no effect
                                 on (undead). The others are told, so two sleepers don't double up.
  SCH        Stratagems          healer: Accession + Regen when 3+ members nearby have no Regen,
                                 Perpetuance + Regen V on the leader; nuker: Immanence self-skillchain
                                 (//vg chain liquefaction|scission|reverberation|detonation|fusion|off)
                                 that the burst module then bursts on.

Normal game commands only (/ma, /ja). Settings under mages.* (//vg set mages.sleep true, ...).
]]

local util = require('vg_util')

local mages = {}
local S, state, h

local function clock() return os.clock() end

local function buff(name) return util.buff_id(name) end
local function has(buffs, name) return util.has_buff(buffs, buff(name)) end

local function has_ja(name)
    local ja = util.ability(name)
    if not ja then return nil end
    local ab = windower.ffxi.get_abilities()
    for _, id in pairs(ab and ab.job_abilities or {}) do
        if id == ja.id then return ja end
    end
    return nil
end

local function ja_ready(name, player)
    if h.amnesia(player) then return nil end
    local ja = has_ja(name)
    if ja and util.ability_ready(ja) then return ja end
    return nil
end

-- Scholar stratagem charges (5; recast_id 231 counts down to full charges).
function mages.charges()
    local per = tonumber(S.mages.strat_secs) or 33
    local r = (windower.ffxi.get_ability_recasts() or {})[231] or 0
    return math.max(0, math.floor((5 * per - r) / per))
end

local function strat(name, player, keep)
    local ja = has_ja(name)
    if not ja or h.amnesia(player) or mages.charges() <= (keep or 0) then return nil end
    return ja
end

local function role() return state.profile and state.profile.role or '' end

------------------------------------------------------------------------
-- WHM / SCH: one -na for the whole party
------------------------------------------------------------------------
-- status_ids: {buff id, spell, status name}; members: party members to look at.
function mages.aoe_na(player, status_ids, members)
    if not S.mages.aoe_na then return false end
    local job = player.main_job
    if job ~= 'WHM' and job ~= 'SCH' then return false end
    for _, entry in ipairs(status_ids) do
        if entry[2] ~= 'Erase' and entry[2] ~= 'Esuna' or (entry[2] == 'Erase' and job == 'WHM') then
            local who, count = nil, 0
            for _, m in ipairs(members) do
                local bl = h.buffs_of(m, player)
                if bl and m.hpp > 0 and util.has_buff(bl, entry[1]) then
                    count = count + 1
                    who = who or m
                end
            end
            local spell = util.spell(entry[2])
            if count >= 2 and spell and util.spell_ready(spell, player) then
                local ja_name = job == 'WHM' and 'Divine Seal' or 'Accession'
                if has(player.buffs, ja_name) then
                    local tgt = who.name == player.name and '<me>' or who.name
                    return h.cast(spell, tgt, ('%s on %d members (%s)'):format(entry[3], count, ja_name))
                end
                local ok = job == 'WHM' and ja_ready('Divine Seal', player)
                    or (job == 'SCH' and (has(player.buffs, 'Light Arts') or has(player.buffs, 'Addendum: White'))
                        and strat('Accession', player))
                if ok and not h.recently('ja:' .. ok.en .. ':<me>', 4) then
                    h.log(('%s: %d members have %s'):format(ok.en, count, entry[3]))
                    return h.use_ja(ok, '<me>')
                end
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Bar spells
------------------------------------------------------------------------
local BAR = {
    fire    = { 'Barfira', 'Barfire', 'amnesia' },
    ice     = { 'Barblizzara', 'Barblizzard', 'paralyze' },
    wind    = { 'Baraera', 'Baraero', 'silence' },
    earth   = { 'Barstonra', 'Barstone', 'petrify' },
    thunder = { 'Barthundra', 'Barthunder', '' },
    water   = { 'Barwatera', 'Barwater', 'poison' },
}
local BAR_STATUS = {
    sleep = { 'Barsleepra', 'Barsleep' }, poison = { 'Barpoisonra', 'Barpoison' },
    paralyze = { 'Barparalyzra', 'Barparalyze' }, blind = { 'Barblindra', 'Barblind' },
    silence = { 'Barsilencera', 'Barsilence' }, petrify = { 'Barpetra', 'Barpetrify' },
    virus = { 'Barvira', 'Barvirus' }, amnesia = { 'Baramnesra', 'Baramnesia' },
}
local ALIAS = { blizzard = 'ice', aero = 'wind', stone = 'earth', lightning = 'thunder', ['nil'] = 'off', none = 'off' }

-- The spells this character keeps up for the current bar setting.
function mages.bar_spells(player)
    local el = BAR[S.mages.bar or '']
    if not el then return {} end
    local st = BAR_STATUS[(S.mages.bar_status ~= '' and S.mages.bar_status) or el[3]]
    local out = {}
    for _, pair in ipairs({ { el[1], el[2] }, st or {} }) do
        local ra, single = util.spell(pair[1]), util.spell(pair[2])
        if ra and util.can_cast(ra, player) then out[#out + 1] = ra
        elseif single and util.can_cast(single, player) then out[#out + 1] = single end
    end
    return out
end

function mages.bar(player)
    if (S.mages.bar or '') == '' or h.silenced(player) then return false end
    for _, spell in ipairs(mages.bar_spells(player)) do
        if not util.has_buff(player.buffs, spell.status) and util.spell_ready(spell, player)
            and not h.recently('ma:' .. spell.en .. ':<me>', 6) then
            return h.cast(spell, '<me>', 'bar ' .. S.mages.bar)
        end
    end
    return false
end

-- //vg bar <element> [status] | off  (on the leader it also goes to the alts)
function mages.set_bar(player, el, st, quiet)
    el = (el or ''):lower(); st = (st or ''):lower()
    el = ALIAS[el] or el
    if el ~= 'off' and not BAR[el] then
        h.log('Usage: //vg bar fire|ice|wind|earth|thunder|water [sleep|poison|paralyze|blind|silence|petrify|virus|amnesia] | off')
        return false
    end
    if st ~= '' and not BAR_STATUS[st] then st = '' end
    S.mages.bar = el == 'off' and '' or el
    S.mages.bar_status = st
    if not quiet then
        local names = {}
        for _, s in ipairs(mages.bar_spells(player)) do names[#names + 1] = s.en end
        h.log(el == 'off' and 'Bar spells off' or ('Bar spells: %s'):format(#names > 0 and table.concat(names, ' + ') or el .. ' (none known on this job)'))
        windower.send_ipc_message(('vg_bar %s %s %s'):format(player.name, el, st ~= '' and st or '-'))
    end
    return true
end

function mages.on_bar(player, from, el, st)
    if S.leader == '' or from:lower() ~= S.leader:lower() then return end
    if mages.set_bar(player, el, st ~= '-' and st or '', true) then
        h.log(el == 'off' and 'Bar spells off' or ('Bar spells: %s (from %s)'):format(el, from))
    end
end

------------------------------------------------------------------------
-- Paladin in the party?  (Majesty seen on someone, or a Vanguard PLD said hello)
------------------------------------------------------------------------
function mages.pld_in_party(player, members)
    if S.mages.pld then return true end
    local majesty = buff('Majesty')
    for _, m in ipairs(members or h.party_members(20)) do
        local bl = h.buffs_of(m, player)
        if bl and util.has_buff(bl, majesty) then return true end
        local k = mages.jobs[m.name:lower()]
        if k == 'PLD' and m.name ~= player.name then return true end
    end
    return false
end
mages.jobs = {}       -- name (lower) -> main job, from vg_hello

------------------------------------------------------------------------
-- RDM: Saboteur before the big enfeebles, Stymie after a resist
------------------------------------------------------------------------
local BIG = { 'Dia', 'Distract', 'Frazzle' }
local function is_big(name)
    for _, b in ipairs(BIG) do if name:sub(1, #b) == b then return true end end
    return false
end

-- Called by the enfeeble module right before it casts name on mob (record r: tries / landed).
function mages.before_enfeeble(player, mob, name, r)
    if player.main_job ~= 'RDM' then return false end
    local spell = util.spell(name)
    if not spell or not util.spell_ready(spell, player) or h.recently('ma:' .. spell.en .. ':<bt>', 4) then return false end
    state.sabo = state.sabo or {}
    if S.mages.saboteur and r.tries == 0 and is_big(name) and state.sabo[mob.id] == nil
        and not has(player.buffs, 'Saboteur') then
        local ja = ja_ready('Saboteur', player)
        if ja then
            state.sabo[mob.id] = true
            h.log('Saboteur before ' .. name)
            return h.use_ja(ja, '<me>')
        end
    end
    if S.mages.stymie and r.tries >= 1 and not r.landed and (name:sub(1, 7) == 'Frazzle' or name:sub(1, 8) == 'Distract')
        and not has(player.buffs, 'Stymie') then
        local ja = ja_ready('Stymie', player)
        if ja then
            h.log('Stymie: ' .. name .. ' was resisted, the next one lands')
            return h.use_ja(ja, '<me>')
        end
    end
    return false
end

------------------------------------------------------------------------
-- Sleep the extra mobs
------------------------------------------------------------------------
local SLEEPS = { 'Sleep II', 'Sleep', 'Foe Lullaby II', 'Foe Lullaby', 'Sleepga II', 'Sleepga', 'Horde Lullaby II', 'Horde Lullaby' }
local SLEEP_SET = {}
for _, n in ipairs(SLEEPS) do SLEEP_SET[n] = true end
local UNDEAD = { 'skeleton', 'ghoul', 'ghast', 'corse', 'wight', 'ghost', 'phantom', 'lich', 'shade', 'bones',
                 'mummy', 'vampyr', 'revenant', 'doom', 'draugar', 'fomor' }
local NO_EFFECT = { [75] = true, [283] = true, [156] = true }
local LANDED = { [236] = true, [237] = true, [2] = true, [252] = true, [270] = true }
local RESISTED = { [85] = true, [284] = true, [653] = true, [654] = true, [655] = true, [656] = true }

local function undead(name)
    name = name:lower()
    for _, w in ipairs(UNDEAD) do if name:find(w, 1, true) then return true end end
    return false
end

function mages.sleep_candidates(player)
    local out = {}
    local party_idx, party_ids = {}, {}
    for _, m in ipairs(h.party_members()) do
        if m.mob then party_idx[m.mob.index] = true; party_ids[m.mob.id] = true end
    end
    local l = h.leader_mob(player)
    local main = l and l.target_index or nil
    if not main then
        local t = windower.ffxi.get_mob_by_target('t')
        main = t and t.index
    end
    if not main then return out end
    local skip = {}
    for _, n in ipairs(util.split(S.mages.sleep_skip or '', ',')) do skip[n:lower()] = true end
    state.slept = state.slept or {}
    state.sleep_immune = state.sleep_immune or {}
    for _, mob in pairs(windower.ffxi.get_mob_array()) do
        if mob.is_npc and mob.spawn_type == 16 and mob.status == 1 and (mob.hpp or 0) > 0 and mob.valid_target ~= false
            and mob.index ~= main and util.dist(mob) <= 20
            and (party_idx[mob.target_index] or party_ids[mob.claim_id])
            and not state.sleep_immune[mob.id] and not undead(mob.name) and not skip[mob.name:lower()]
            and not ((state.slept[mob.id] or 0) > clock()) then
            out[#out + 1] = mob
        end
    end
    table.sort(out, function(a, b) return util.dist(a) < util.dist(b) end)
    return out
end

function mages.crowd(player)
    if not S.mages.sleep or h.silenced(player) then return false end
    local cands = mages.sleep_candidates(player)
    local mob = cands[1]
    if not mob then return false end
    -- 2+ extra mobs: an area sleep first (Horde Lullaby / Sleepga), from the Bard guide.
    local order = SLEEPS
    if #cands >= 2 then
        order = { 'Horde Lullaby II', 'Horde Lullaby', 'Sleepga II', 'Sleepga' }
        for _, n in ipairs(SLEEPS) do order[#order + 1] = n end
    end
    for _, name in ipairs(order) do
        local spell = util.spell(name)
        if spell and util.spell_ready(spell, player) then
            state.slept[mob.id] = clock() + 8             -- casting; the result decides how long
            windower.send_ipc_message(('vg_sleep %d 8'):format(mob.id))
            return h.cast(spell, tostring(mob.id), 'sleep ' .. mob.name .. ' (extra mob)')
        end
    end
    return false
end

function mages.on_sleep(mob_id, secs)
    state.slept = state.slept or {}
    state.slept[tonumber(mob_id)] = clock() + (tonumber(secs) or 8)
end

-- Every action: our sleep results, and a slept mob waking up (it acts again).
function mages.on_action(act, player, res)
    state.slept = state.slept or {}
    state.sleep_immune = state.sleep_immune or {}
    local first = act.targets and act.targets[1]
    local fa = first and first.actions and first.actions[1]
    if act.actor_id == player.id and act.category == 4 and fa then
        local spell = res.spells[act.param]
        if spell and SLEEP_SET[spell.en] then
            for _, t in ipairs(act.targets) do
                local msg = t.actions and t.actions[1] and t.actions[1].message
                if NO_EFFECT[msg] then
                    state.sleep_immune[t.id] = true
                    state.slept[t.id] = nil
                    h.log(spell.en .. ' has no effect on that mob: not trying again')
                elseif LANDED[msg] then
                    local secs = math.floor((spell.duration or 60) * 0.75)
                    state.slept[t.id] = clock() + secs
                    windower.send_ipc_message(('vg_sleep %d %d'):format(t.id, secs))
                elseif RESISTED[msg] then
                    state.slept[t.id] = nil
                    windower.send_ipc_message(('vg_sleep %d 0'):format(t.id))
                end
            end
        end
    elseif state.slept[act.actor_id] and (act.category == 1 or act.category == 7 or act.category == 11) then
        state.slept[act.actor_id] = nil                    -- it woke up and attacks: sleep it again
    end
end

------------------------------------------------------------------------
-- SCH stratagems
------------------------------------------------------------------------
local REGENS = { 'Regen V', 'Regen IV', 'Regen III', 'Regen II', 'Regen' }
local CHAINS = {
    liquefaction  = { 'Stone', 'Fire' },
    scission      = { 'Fire', 'Stone' },
    reverberation = { 'Stone', 'Water' },
    detonation    = { 'Stone', 'Aero' },
    fusion        = { 'Fire', 'Thunder' },
}
mages.CHAINS = CHAINS

local function best(list, player)
    for _, n in ipairs(list) do
        local s = util.spell(n)
        if s and util.spell_ready(s, player) then return s end
    end
end

local function has_regen(bl) return util.has_buff(bl, 42) or util.has_buff(bl, 539) end

local function sch_healer(player)
    if not (has(player.buffs, 'Light Arts') or has(player.buffs, 'Addendum: White')) then return false end
    if not h.party_engaged(player) then return false end
    -- Accession + Regen for the whole party.
    if S.mages.accession then
        local missing = 0
        for _, m in ipairs(h.party_members(10)) do
            local bl = h.buffs_of(m, player)
            if bl and m.hpp > 0 and not has_regen(bl) then missing = missing + 1 end
        end
        if missing >= 3 then
            if has(player.buffs, 'Accession') then
                local s = best(REGENS, player)
                if s then return h.cast(s, '<me>', ('Accession Regen: %d members'):format(missing)) end
            elseif not h.recently('acc_regen', 20) then
                local ja = strat('Accession', player, 1)
                if ja then h.mark('acc_regen') h.log('Accession: Regen for the party') return h.use_ja(ja, '<me>') end
            end
        end
    end
    -- Perpetuance + Regen V on the leader (lasts much longer).
    if S.mages.perpetuance and S.leader ~= '' and S.leader:lower() ~= player.name:lower() then
        for _, m in ipairs(h.party_members(20)) do
            if m.name:lower() == S.leader:lower() then
                local bl = h.buffs_of(m, player)
                if bl and m.hpp > 0 and not has_regen(bl) then
                    local s = util.spell('Regen V')
                    if s and util.spell_ready(s, player) then
                        if has(player.buffs, 'Perpetuance') then return h.cast(s, m.name, 'Perpetuance Regen V') end
                        if not h.recently('perp_regen', 20) then
                            local ja = strat('Perpetuance', player, 1)
                            if ja then h.mark('perp_regen') h.log('Perpetuance: Regen V on ' .. m.name) return h.use_ja(ja, '<me>') end
                        end
                    end
                end
            end
        end
    end
    return false
end

local function closer(base, player)
    local s = util.spell(base .. ' II')
    if s and util.spell_ready(s, player) then return s end
    s = util.spell(base)
    return s and util.spell_ready(s, player) and s or nil
end

local function sch_nuker(player)
    local chain = CHAINS[S.mages.chain or '']
    if not chain then return false end
    if not (has(player.buffs, 'Dark Arts') or has(player.buffs, 'Addendum: Black')) then return false end
    local bt = h.battle_target()
    if not bt or util.dist(bt) > 21 or not h.party_engaged(player) then state.imm = nil return false end
    local imm = state.imm
    if imm and (clock() - imm.t > 15 or imm.mob ~= bt.id) then imm = nil state.imm = nil end
    if not imm then
        if h.recently('imm_chain', tonumber(S.mages.chain_every) or 40) or player.vitals.mpp < 30 then return false end
        if mages.charges() < 2 or not util.spell_ready(util.spell(chain[1]), player) then return false end
        imm = { step = 1, t = clock(), mob = bt.id }
        state.imm = imm
        h.mark('imm_chain')
    end
    local spell = imm.step == 1 and util.spell(chain[1]) or closer(chain[2], player)
    if not spell or not util.spell_ready(spell, player) then return false end
    if not has(player.buffs, 'Immanence') then
        if h.recently('ja:Immanence:<me>', 3) then return false end
        local ja = strat('Immanence', player)
        if not ja then state.imm = nil return false end
        return h.use_ja(ja, '<me>')
    end
    local step = imm.step
    imm.step, imm.t = imm.step + 1, clock()
    if step >= 2 then state.imm = nil end
    return h.cast(spell, '<bt>', step == 1 and ('Immanence chain: open (%s)'):format(S.mages.chain)
        or ('Immanence chain: close -> %s'):format(S.mages.chain))
end

function mages.sch(player)
    if player.main_job ~= 'SCH' or h.silenced(player) then return false end
    if role() == 'healer' then return sch_healer(player) end
    if role() == 'nuker' and S.mages.immanence then return sch_nuker(player) end
    return false
end

function mages.set_chain(name)
    name = (name or ''):lower()
    if name ~= 'off' and not CHAINS[name] then
        h.log('Usage: //vg chain liquefaction|scission|reverberation|detonation|fusion|off')
        return false
    end
    S.mages.chain = name == 'off' and '' or name
    S.mages.immanence = name ~= 'off'
    h.log(name == 'off' and 'Immanence skillchains off'
        or ('Immanence skillchain: %s (%s -> %s)'):format(name, CHAINS[name][1], CHAINS[name][2]))
    return true
end

function mages.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return mages
