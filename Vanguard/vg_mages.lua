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

-- Scholar stratagem charges and use: vg_strat (main or sub SCH, charges by level).
function mages.charges() return require('vg_strat').charges() end

local function strat(name, player, keep)
    local ja = require('vg_strat').has(name)
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
    local sch = job == 'SCH' or player.sub_job == 'SCH'
    if job ~= 'WHM' and not sch then return false end
    for _, entry in ipairs(status_ids) do
        -- (Erase only above 40 % MP: the mobs put those back at once, the MP is for cures - CharB 2026-11-21)
        local low_mp = ((player.vitals or {}).mpp or 100) < 40
        if (entry[2] ~= 'Erase' and entry[2] ~= 'Esuna' or (entry[2] == 'Erase' and job == 'WHM')) and not (low_mp and entry[2] == 'Erase') then
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
                local tgt = who.name == player.name and '<me>' or who.name
                for _, ja_name in ipairs({ 'Divine Seal', 'Accession' }) do
                    if has(player.buffs, ja_name) then
                        return h.cast(spell, tgt, ('%s on %d members (%s)'):format(entry[3], count, ja_name))
                    end
                end
                -- WHM: Divine Seal; Scholar (main or sub) in Light Arts: Accession (WHM/SCH: either)
                local ok = job == 'WHM' and ja_ready('Divine Seal', player)
                    or (sch and (has(player.buffs, 'Light Arts') or has(player.buffs, 'Addendum: White'))
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
for _, n in ipairs({ 'Repose', 'Dream Flower', 'Sheep Song', 'Yawn', 'Soporific' }) do SLEEP_SET[n] = true end   -- (vg_charm's too)
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
-- Enfeebler mode (1.2.0, Silmaril audit 1.3): keep up to enfeebler.count mobs enfeebled - the battle target first,
-- then the other mobs fighting the party (nearest first), then (enfeebler.pull) unclaimed mobs within enfeebler.range,
-- only to fill the count. enfeebler.mobs = names (part of the name, comma list) it may take; '' = any.
-- Spells: enfeebler.spells, else debuff.list, in order; each mob's records (state.debuffs) are the same ones the
-- action handler fills (landed / resisted) and the other characters share (vg_share.debuff): no double Slow.
-- Who owns what: with enfeebler.on it owns enfeebling (do_debuff in Vanguard.lua stands aside); sleeping extra mobs
-- stays with mages.crowd while mages.sleep is on (the enfeebler then skips sleep spells). Sleep spells never go on an
-- unclaimed mob (no sleeping as a pull) nor on the battle target. Healing first: it waits while a party member is
-- under enfeebler.wait_hp (and pulling waits for farm.party_wait too), and while following a leader on the move.
------------------------------------------------------------------------
local function enf_named(mob, names)
    if #names == 0 then return true end
    local n = (mob.name or ''):lower()
    for _, w in ipairs(names) do if n:find(w, 1, true) then return true end end
    return false
end

-- Following a leader who is walking (or walking after him right now): no casting, it would stop the follow.
function mages.enf_following(player)
    if not S.modules.follow then return false end
    local l = h.leader_mob(player)
    if not l or not l.x then return false end
    local t, lp = clock(), state.enf_leader
    if lp and (math.abs(l.x - lp.x) > 0.1 or math.abs(l.y - lp.y) > 0.1) then state.enf_leader_moved = t end
    state.enf_leader = { x = l.x, y = l.y }
    if not lp then return true end                     -- (first look: one pass to see whether he walks)
    if state.enf_leader_moved and t - state.enf_leader_moved < 1.5 then return true end
    return state.running and state.run_by == 'move' or false
end

-- A party member (a player, not a trust) under enfeebler.wait_hp: the cures come first.
function mages.enf_party_low(player)
    local need = tonumber(S.enfeebler.wait_hp) or 50
    for _, m in ipairs(h.party_members()) do
        if m.mob and not m.mob.is_npc and (m.hpp or 100) > 0 and (m.hpp or 100) < need then return m end
    end
    return nil
end

-- Every mob this character could keep enfeebled, in its own order (not cut to enfeebler.count): the battle target,
-- the mobs fighting the party (nearest first), then (enfeebler.pull, party ready) unclaimed ones.
-- Each: { mob = , bt = true for the battle target, pull = true for an unclaimed one }. The team planner gets this list.
function mages.enfeebler_candidates(player)
    local E = S.enfeebler
    local range = math.min(tonumber(E.range) or 20, 21)
    local names = {}
    for _, n in ipairs(util.split(E.mobs or '', ',')) do names[#names + 1] = n:lower() end
    local party_idx, party_ids = {}, {}
    for _, m in ipairs(h.party_members()) do
        if m.mob then party_idx[m.mob.index] = true; party_ids[m.mob.id] = true end
    end
    util.alliance_ids(party_ids)
    local bt = h.battle_target()
    local fighting, free = {}, {}
    -- a mob asleep (mages.crowd here or on another character, shared as vg_sleep) is left alone: Dia / Bio would wake
    -- it (sleeping extra mobs wins over enfeebling them)
    local slept = state.slept or {}
    for _, mob in pairs(windower.ffxi.get_mob_array()) do
        if mob.is_npc and mob.spawn_type == 16 and (mob.hpp or 0) > 0 and mob.valid_target ~= false
            and util.dist(mob) <= range and enf_named(mob, names) and not (bt and mob.id == bt.id)
            and not ((slept[mob.id] or 0) > clock()) then
            local claim = mob.claim_id or 0
            if party_idx[mob.target_index] or party_ids[claim] then
                if mob.status == 1 or party_ids[claim] then fighting[#fighting + 1] = mob end
            elseif claim == 0 and E.pull then
                free[#free + 1] = mob
            end
        end
    end
    local near = function(a, b) return util.dist(a) < util.dist(b) end
    table.sort(fighting, near)
    table.sort(free, near)
    local out = {}
    if bt and util.dist(bt) <= range and enf_named(bt, names) then out[1] = { mob = bt, bt = true } end
    for _, mob in ipairs(fighting) do out[#out + 1] = { mob = mob } end
    -- pulling only fills the count (enfeebler_mobs), and only when the party is ready (farm.party_wait, when that's on)
    if #free > 0 and not require('vg_farm').party_wait(player) then
        for _, mob in ipairs(free) do out[#out + 1] = { mob = mob, pull = true } end
    end
    return out
end

-- The mobs to keep enfeebled, in order (at most enfeebler.count). Each: { mob = , pull = true for an unclaimed one }.
-- Team planner (Vanguard Control 2.0.0, vg_plan): while a fresh plan names this character's mobs, only those (no two
-- characters on one mob; an empty list = none now); no fresh plan = this character's own pick, as before.
function mages.enfeebler_mobs(player)
    local count = math.max(1, math.floor(tonumber(S.enfeebler.count) or 1))
    local all = mages.enfeebler_candidates(player)
    local mine = require('vg_plan').enf_for(player)
    -- pulling only fills the count: never while the party already fights `count` mobs (also with a plan, which may
    -- give the mobs we fight to someone else - that is no reason to pull a new one)
    local fighting = 0
    for _, c in ipairs(all) do if not c.pull then fighting = fighting + 1 end end
    local out = {}
    for _, c in ipairs(all) do
        -- (the list is in order: fighting mobs come before unclaimed ones, so a pull only fills the count)
        if (not mine or mine.set[c.mob.id]) and not (c.pull and fighting >= count) then out[#out + 1] = c end
        if #out >= count then break end
    end
    return out
end

function mages.enfeebler(player)
    local E = S.enfeebler
    if not E or not E.on or h.silenced(player) then return false end
    if mages.enf_party_low(player) then return false end
    if mages.enf_following(player) then return false end
    local list = util.split((E.spells or '') ~= '' and E.spells or (S.debuff.list or ''), ',')
    if #list == 0 then return false end
    local retries = tonumber(S.debuff.retries) or 1
    local share = require('vg_share')
    for _, c in ipairs(mages.enfeebler_mobs(player)) do
        local mob = c.mob
        state.debuffs[mob.id] = state.debuffs[mob.id] or {}
        local rec = state.debuffs[mob.id]
        for _, name in ipairs(list) do
            local spell = util.spell(name)
            local sleep = spell and SLEEP_SET[spell.en]
            -- (no sleeping as a pull, nor the mob we fight; mages.crowd owns the sleeping of extra mobs when it's on)
            local skip = not spell or (sleep and (c.pull or c.bt or S.mages.sleep))
            if not skip then
                local r = rec[spell.en] or { tries = 0, landed = false }
                rec[spell.en] = r
                local tgt = c.bt and '<bt>' or tostring(mob.id)
                if not share.debuff_blocked(r) and r.tries <= retries and util.spell_ready(spell, player)
                    and not h.recently('ma:' .. spell.en .. ':' .. tgt, 4) then
                    if c.bt and mages.before_enfeeble(player, mob, spell.en, r) then return true end
                    local why = ('enfeebler: %s%s'):format(mob.name or 'mob', c.pull and ' (pull)' or '')
                    if h.cast(spell, tgt, why) then
                        r.tries = r.tries + 1
                        share.debuff(mob.id, spell.en, 'cast')
                        return true
                    end
                    if state.stand_wait and clock() - state.stand_wait < 0.3 then return true end   -- (stopping to cast it)
                    return false                       -- (refused: MP kept for cures and the like - try again later)
                end
            end
        end
    end
    return false
end

-- //vg enfeebler on|off|count N|mobs <list>|pull on|off|stay on|off|spells <list>|status
function mages.enfeebler_cmd(args)
    local E = S.enfeebler
    local sub = (args[1] or 'status'):lower()
    local rest = table.concat(args, ' ', 2)
    local v = (args[2] or ''):lower()
    if sub == 'on' or sub == 'off' then E.on = (sub == 'on')
    elseif sub == 'count' then
        local n = tonumber(args[2])
        if not n or n < 1 or n > 8 then h.log('Enfeebler: count 1 to 8') return false end
        E.count = math.floor(n)
    elseif sub == 'mobs' then E.mobs = (rest == 'any' or rest == 'none' or rest == 'clear') and '' or rest
    elseif sub == 'spells' then E.spells = (rest == 'default' or rest == 'clear') and '' or rest
    elseif sub == 'pull' or sub == 'stay' then
        if v ~= 'on' and v ~= 'off' then h.log('Usage: //vg enfeebler ' .. sub .. ' on|off') return false end
        E[sub] = (v == 'on')
    elseif sub == 'range' then
        local n = tonumber(args[2])
        if not n or n < 1 or n > 21 then h.log('Enfeebler: range 1 to 21 yalms') return false end
        E.range = n
    elseif sub ~= 'status' then
        h.log('Usage: //vg enfeebler on|off | count N | mobs <name,name>|any | pull on|off | stay on|off | spells <list>|default | range N')
        return false
    end
    h.log(('Enfeebler %s: up to %d mob(s), %s, spells %s%s%s'):format(E.on and 'on' or 'off', tonumber(E.count) or 1,
        (E.mobs or '') ~= '' and ('only ' .. E.mobs) or 'any mob fighting the party',
        (E.spells or '') ~= '' and E.spells or ('the debuff list (' .. (S.debuff.list or '') .. ')'),
        E.pull and (', pulls unclaimed mobs within %d\''):format(tonumber(E.range) or 20) or '',
        E.stay and ', does not move' or ''))
    return sub ~= 'status'
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

------------------------------------------------------------------------
-- Sortie round (his request 2026-11-25: "research sortie and the role sch can play with completing objectives";
-- RESEARCH.md "Sortie and Scholar"). Under Immanence an elemental spell carries its element's skillchain property
-- (bg-wiki Immanence / Skillchain): Fire Liquefaction, Stone Scission, Water Reverberation, Aero Detonation,
-- Blizzard Induration, Thunder Impaction, Luminohelix Transfixion, Noctohelix Compression. Spells only have level-1
-- properties, so a chain goes on while each result is level 1 and ends on a level-2 result (Fusion, Fragmentation,
-- Gravitation, Distortion). The planner finds N spells in a row (Sortie D: a 4-step skillchain) ending on the chain
-- picked, or on one that bursts the target's weak element.
------------------------------------------------------------------------
local PROP = { fire = 'Liquefaction', earth = 'Scission', water = 'Reverberation', wind = 'Detonation',
               ice = 'Induration', thunder = 'Impaction', light = 'Transfixion', dark = 'Compression' }
local SC = {     -- opener > closer (a level-1 property) = result (bg-wiki Skillchain table)
    ['Compression>Transfixion'] = 'Transfixion',
    ['Induration>Compression'] = 'Compression', ['Transfixion>Compression'] = 'Compression',
    ['Impaction>Liquefaction'] = 'Liquefaction', ['Scission>Liquefaction'] = 'Liquefaction',
    ['Liquefaction>Scission'] = 'Scission', ['Detonation>Scission'] = 'Scission',
    ['Transfixion>Reverberation'] = 'Reverberation', ['Scission>Reverberation'] = 'Reverberation',
    ['Impaction>Detonation'] = 'Detonation', ['Compression>Detonation'] = 'Detonation', ['Scission>Detonation'] = 'Detonation',
    ['Reverberation>Induration'] = 'Induration',
    ['Induration>Impaction'] = 'Impaction', ['Reverberation>Impaction'] = 'Impaction',
    ['Liquefaction>Impaction'] = 'Fusion', ['Induration>Reverberation'] = 'Fragmentation',
    ['Detonation>Compression'] = 'Gravitation', ['Transfixion>Scission'] = 'Distortion',
}
local LEVEL2 = { Fusion = true, Fragmentation = true, Gravitation = true, Distortion = true }
local BURSTS = { Liquefaction = { 'fire' }, Scission = { 'earth' }, Reverberation = { 'water' }, Detonation = { 'wind' },
                 Induration = { 'ice' }, Impaction = { 'thunder' }, Transfixion = { 'light' }, Compression = { 'dark' },
                 Fusion = { 'fire', 'light' }, Fragmentation = { 'wind', 'thunder' }, Gravitation = { 'earth', 'dark' },
                 Distortion = { 'ice', 'water' } }
local NUKE = { fire = 'Fire', earth = 'Stone', water = 'Water', wind = 'Aero', ice = 'Blizzard', thunder = 'Thunder' }
local HELIX = { fire = 'Pyrohelix', earth = 'Geohelix', water = 'Hydrohelix', wind = 'Anemohelix', ice = 'Cryohelix',
                thunder = 'Ionohelix', light = 'Luminohelix', dark = 'Noctohelix' }
local STORM = { fire = 'Firestorm', ice = 'Hailstorm', wind = 'Windstorm', earth = 'Sandstorm', thunder = 'Thunderstorm',
                water = 'Rainstorm', light = 'Aurorastorm', dark = 'Voidstorm' }
local STORM_ORDER = { 'fire', 'ice', 'wind', 'earth', 'thunder', 'water', 'light', 'dark' }   -- buff 178+i, II 589+i
local ELEMENT_ALIAS = { stone = 'earth', aero = 'wind', blizzard = 'ice', lightning = 'thunder', ice = 'ice', fire = 'fire',
                        earth = 'earth', wind = 'wind', thunder = 'thunder', water = 'water', light = 'light', dark = 'dark' }
-- (non-helix elements first: plain nukes are faster and have no long recast; light / dark only as Helix)
local TRY = { 'earth', 'fire', 'water', 'wind', 'ice', 'thunder', 'light', 'dark' }
mages.PROP, mages.SC, mages.BURSTS = PROP, SC, BURSTS

local function burst_has(result, element)
    for _, e in ipairs(BURSTS[result] or {}) do if e == element then return true end end
    return false
end

-- N elements in a row that keep a skillchain going: ending on the chain named (goal), or else on one that bursts the
-- element given (a level-2 one preferred). nil when none fits.
function mages.plan(steps, goal, element)
    steps = math.max(2, math.min(5, tonumber(steps) or 2))
    goal = goal and goal ~= '' and (goal:sub(1, 1):upper() .. goal:sub(2):lower()) or nil
    local found
    local function ok_end(result)
        if goal then return result == goal end
        if element then return burst_has(result, element) and (LEVEL2[result] or not found) end
        return true
    end
    local seq = {}
    local function walk(cur)
        if found and (goal or LEVEL2[found.result]) then return end
        if #seq == steps then
            if ok_end(cur) then
                local copy = {}
                for i, e in ipairs(seq) do copy[i] = e end
                found = { list = copy, result = cur }
            end
            return
        end
        for _, e in ipairs(TRY) do
            local res = #seq == 0 and PROP[e] or SC[cur .. '>' .. PROP[e]]
            -- a level-2 result ends the chain: only on the last spell
            if res and (#seq == 0 or not LEVEL2[res] or #seq == steps - 1) then
                seq[#seq + 1] = e
                walk(#seq == 1 and PROP[e] or res)
                seq[#seq] = nil
                if found and (goal or LEVEL2[found.result]) then return end
            end
        end
    end
    walk(nil)
    return found and found.list, found and found.result
end

-- Element by target (Sortie bosses and Naakuals): mages.elements = "Name:element,Name:element" (part of the name).
function mages.target_element(mob)
    if not mob or not mob.name then return nil end
    -- Degei / Aita in Sortie: the element their last TP move made them weak to (vg_sortie)
    local proc = require('vg_sortie').element_for(mob)
    if proc then return proc end
    local name = mob.name:lower()
    for _, pair in ipairs(util.split(S.mages.elements or '', ',')) do
        local n, e = pair:match('^%s*(.-)%s*:%s*(%a+)%s*$')
        if n and n ~= '' and name:find(n:lower(), 1, true) then return ELEMENT_ALIAS[e:lower()] end
    end
    return nil
end

-- The spell for one step: light / dark only as Helix; the last step a Helix when "close with a Helix" is on.
local function step_spell(element, last, player)
    local function ready(n) local s = util.spell(n) return s and util.can_cast(s, player) and util.spell_ready(s, player) and s or nil end
    if HELIX[element] and (last and S.mages.helix_close or not NUKE[element]) then
        local tier = last and tostring(S.mages.helix_tier or '1') == '2'
        local s = tier and ready(HELIX[element] .. ' II') or ready(HELIX[element]) or (not tier and ready(HELIX[element] .. ' II'))
        if s or not NUKE[element] then return s end
    end
    if last then return ready(NUKE[element] .. ' II') or ready(NUKE[element]) end
    return ready(NUKE[element]) or ready(NUKE[element] .. ' II')
end
mages.step_spell = step_spell

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
    local st = require('vg_strat')
    -- Regen for the whole party: only when Accession can be spent (the stratagem manager uses it on the cast).
    if S.mages.accession then
        local missing = 0
        for _, m in ipairs(h.party_members(10)) do
            local bl = h.buffs_of(m, player)
            if bl and m.hpp > 0 and not has_regen(bl) then missing = missing + 1 end
        end
        local can = has(player.buffs, 'Accession')
            or (st.has('Accession') and mages.charges() > (tonumber(S.strat.reserve) or 0))
        if missing >= (tonumber(S.strat.accession_count) or 3) and can and not h.recently('acc_regen', 20) then
            local s = best(REGENS, player)
            if s then h.mark('acc_regen') return h.cast(s, '<me>', ('party Regen: %d members'):format(missing)) end
        end
    end
    -- Regen V on the leader (Perpetuance makes it last much longer).
    if S.mages.perpetuance and S.leader ~= '' and S.leader:lower() ~= player.name:lower() then
        for _, m in ipairs(h.party_members(20)) do
            if m.name:lower() == S.leader:lower() then
                local bl = h.buffs_of(m, player)
                local s = util.spell('Regen V')
                if bl and m.hpp > 0 and not has_regen(bl) and s and util.spell_ready(s, player)
                    and not h.recently('ma:Regen V:' .. m.name, 6) then
                    return h.cast(s, m.name, 'Regen V on ' .. m.name)
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

-- The chain to make on this mob: the element set for it (mages.elements) picks a chain that bursts it, else the chain
-- picked. Returns the elements in order and the result.
function mages.chain_for(mob)
    local steps = tonumber(S.mages.chain_steps) or 2
    local el = mages.target_element(mob)
    if el then
        local list, res = mages.plan(steps, nil, el)
        if list then return list, res, el end
    end
    if (S.mages.chain or '') == '' then return nil end
    local list, res = mages.plan(steps, S.mages.chain)
    return list, res, nil
end

local function sch_nuker(player)
    if (S.mages.chain or '') == '' and (S.mages.elements or '') == '' then return false end
    if not (has(player.buffs, 'Dark Arts') or has(player.buffs, 'Addendum: Black')) then return false end
    local bt = h.battle_target()
    if not bt or util.dist(bt) > 21 or not h.party_engaged(player) then state.imm = nil return false end
    if require('vg_sortie').no_chain(bt) then state.imm = nil return false end    -- (Degei / Aita: a skillchain heals them)
    local imm = state.imm
    -- (each step must land inside the last one's window: 15 s without the next step and it starts over)
    if imm and (clock() - imm.t > 15 or imm.mob ~= bt.id) then imm = nil state.imm = nil end
    if not imm then
        if h.recently('imm_chain', tonumber(S.mages.chain_every) or 40) or player.vitals.mpp < 30 then return false end
        local list, res, el = mages.chain_for(bt)
        if not list then
            if not h.recently('imm_none', 120) then
                h.mark('imm_none')
                h.log(('Immanence chain: no %d-step chain ends on %s'):format(tonumber(S.mages.chain_steps) or 2, el or S.mages.chain))
            end
            return false
        end
        -- every step costs a charge (Immanence): only start what can be finished
        if mages.charges() < #list or not step_spell(list[1], false, player) then return false end
        imm = { step = 1, t = clock(), mob = bt.id, list = list, result = res }
        state.imm = imm
        h.mark('imm_chain')
    end
    local last = imm.step >= #imm.list
    local spell = step_spell(imm.list[imm.step], last, player)
    if not spell then return false end
    if not has(player.buffs, 'Immanence') then
        if h.recently('ja:Immanence:<me>', 3) then return false end
        local ja = strat('Immanence', player)
        if not ja then state.imm = nil return false end
        return h.use_ja(ja, '<me>')
    end
    local step = imm.step
    imm.step, imm.t = imm.step + 1, clock()
    if last then state.imm = nil end
    return h.cast(spell, '<bt>', step == 1 and ('Immanence chain: open, %d steps -> %s'):format(#imm.list, imm.result)
        or last and ('Immanence chain: step %d, close -> %s'):format(step, imm.result)
        or ('Immanence chain: step %d'):format(step))
end

------------------------------------------------------------------------
-- Magic killing blow (Sortie A: "vanquish 3 Abject foes with magic for the killing blow" - AoE counts only on the
-- primary target, DoT doesn't count): a nearly dead mob gets a single-target nuke. mages.finish_hp = 0 off.
------------------------------------------------------------------------
local FINISH_TIERS = { ' V', ' IV', ' III', ' II', '' }

-- The smallest ready single-target nuke of an element on <bt> (Sortie procs: 0 damage is enough, speed matters).
function mages.quick_nuke(player, element, why)
    local base = NUKE[element]
    if not base then return false end
    for i = #FINISH_TIERS, 1, -1 do
        local s = util.spell(base .. FINISH_TIERS[i])
        if s and util.can_cast(s, player) and util.spell_ready(s, player) and (player.vitals.mp or 0) >= (s.mp_cost or 0) then
            return h.cast(s, '<bt>', why)
        end
    end
    -- (a Helix works too)
    local hx = util.spell(HELIX[element])
    if hx and util.can_cast(hx, player) and util.spell_ready(hx, player) then return h.cast(hx, '<bt>', why) end
    return false
end

-- With the Sortie setup on, the Scholar changes with the sector (vg_sortie): A Abject foes must die to magic (killing
-- blow at 15 %), D a 4-step skillchain on 3 Demisang, elsewhere 2-step chains for the shortest burst cycle.
function mages.sector_mode(sec)
    if not S.mages.sortie_auto then return end
    local steps, fin = 2, 0
    if sec == 'A' then fin = 15 elseif sec == 'D' then steps = 4 end
    if S.mages.chain_steps == steps and S.mages.finish_hp == fin then return end
    S.mages.chain_steps, S.mages.finish_hp = steps, fin
    state.imm = nil
    h.log(('Sortie sector %s: %d-step chains%s'):format(sec, steps, fin > 0 and ', magic killing blow at 15%' or ''))
end
function mages.finisher(player)
    local at = tonumber(S.mages.finish_hp) or 0
    if at <= 0 or h.silenced(player) or state.imm then return false end
    local bt = h.battle_target()
    if not bt or (bt.hpp or 100) > at or (bt.hpp or 0) <= 0 or util.dist(bt) > 21 then return false end
    if h.recently('finish_nuke:' .. bt.id, 4) then return false end
    local order = {}
    local el = mages.target_element(bt)
    if el and NUKE[el] then order[1] = el end
    for _, e in ipairs({ 'thunder', 'fire', 'ice', 'wind', 'earth', 'water' }) do if e ~= el then order[#order + 1] = e end end
    -- (smallest tier that's ready first: it only has to finish the mob, and the fastest cast lands before a melee hit)
    for _, e in ipairs(order) do
        for i = #FINISH_TIERS, 1, -1 do
            local s = util.spell(NUKE[e] .. FINISH_TIERS[i])
            if s and util.can_cast(s, player) and util.spell_ready(s, player) and (player.vitals.mp or 0) >= (s.mp_cost or 0) then
                h.mark('finish_nuke:' .. bt.id)
                return h.cast(s, '<bt>', ('magic killing blow (%s at %d%%)'):format(bt.name or 'mob', bt.hpp or 0))
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Storm and Klimaform for the target's element (mages.storm_auto): the Storm of the weak element replaces any other.
------------------------------------------------------------------------
local function storm_on(buffs)
    for i, e in ipairs(STORM_ORDER) do
        if util.has_buff(buffs, 177 + i) or util.has_buff(buffs, 588 + i) then return e end
    end
    return nil
end
mages.storm_on = storm_on

function mages.storm(player)
    if not S.mages.storm_auto or player.main_job ~= 'SCH' or h.silenced(player) then return false end
    local bt = h.battle_target()
    if not bt or not h.party_engaged(player) then return false end
    local el = mages.target_element(bt)
    if not el then return false end
    local function ready(n) local s = util.spell(n) return s and util.can_cast(s, player) and util.spell_ready(s, player) and s or nil end
    if storm_on(player.buffs) ~= el and not h.recently('storm_el', 8) then
        local s = ready(STORM[el] .. ' II') or ready(STORM[el])
        if s then h.mark('storm_el') return h.cast(s, '<me>', ('%s is weak to %s'):format(bt.name or 'the mob', el)) end
    end
    if (S.mages.klimaform ~= false) and not util.has_buff(player.buffs, 407) and not h.recently('ma:Klimaform:<me>', 10) then
        local s = ready('Klimaform')
        if s then return h.cast(s, '<me>', 'Klimaform') end
    end
    return false
end

-- Bursting: the target's weak element first when the skillchain bursts it.
function mages.burst_order(elements, mob)
    -- Degei / Aita: only the proc element (anything else heals them back); none while it isn't known
    local only = require('vg_sortie').only_element(mob)
    if only then
        local out = {}
        for _, e in ipairs(elements) do if e:lower() == only then out[#out + 1] = e end end
        return out
    end
    local el = mages.target_element(mob)
    if not el then return elements end
    local out = {}
    for _, e in ipairs(elements) do if e:lower() == el then table.insert(out, 1, e) else out[#out + 1] = e end end
    return out
end

function mages.sch(player)
    if player.main_job ~= 'SCH' or h.silenced(player) then return false end
    if role() == 'healer' then
        if sch_healer(player) then return true end
        -- a healer Scholar makes its chains too when "also as healer" is ticked (Sortie: a single Scholar does both)
        return S.mages.immanence and S.mages.chain_healer and sch_nuker(player) or false
    end
    if S.mages.immanence and (role() == 'nuker' or S.mages.chain_healer) then return sch_nuker(player) end
    return false
end

-- Sortie bosses and Naakuals and the element to use on them (FFXIAH Sortie mage guide, Kylos 2025; RESEARCH.md):
-- Naakual weaknesses Bztavian Ice/Fire, Rockfin Thunder/Stone, Gabbrath Thunder/Water, Yggdreant Fire/Wind,
-- Waktza Earth/Ice, Cehuetzi Fire; Stone on Ghatjot and Dhartok, Fire on Skomora and Triboulex, Fire on the Acuex in A.
mages.SORTIE_ELEMENTS = 'Bztavian:ice,Rockfin:thunder,Gabbrath:thunder,Yggdreant:fire,Waktza:earth,Cehuetzi:fire,'
    .. 'Ghatjot:earth,Dhartok:earth,Skomora:fire,Triboulex:fire,Acuex:fire'

-- //vg sortie: the Scholar set up for Sortie in one go (his request 2026-11-25); //vg sortie d: 4-step chains for
-- Sector D's objective. Saved as a profile from the app.
function mages.sortie(which)
    which = (which or ''):lower()
    S.mages.elements = mages.SORTIE_ELEMENTS
    S.mages.helix_close, S.mages.helix_tier = true, 1
    S.mages.chain_healer = true
    S.mages.storm_auto, S.mages.klimaform = true, true
    S.mages.finish_hp = 15
    S.mages.chain_every = 20
    S.mages.chain, S.mages.immanence = 'fusion', true
    S.mages.chain_steps = which == 'd' and 4 or 2
    S.mages.sortie_auto = true                           -- (then the sector decides: vg_sortie / mages.sector_mode)
    S.modules.burst = true
    h.log(('Sortie setup: %d-step Immanence chains closed with a Helix (Fusion, or the boss / Naakual\'s weak element), '
        .. 'its Storm + Klimaform, bursts on, magic killing blow at 15%%%s')
        :format(S.mages.chain_steps, which == 'd' and ' - Sector D: 4-step chains (//vg sortie for 2-step)' or ''))
    return true
end

function mages.set_chain(name, steps)
    name = (name or ''):lower()
    local n = tonumber(steps)
    if name ~= 'off' and not BURSTS[name:sub(1, 1):upper() .. name:sub(2)] then
        h.log('Usage: //vg chain <skillchain> [2-5 steps] | off   (liquefaction, scission, reverberation, detonation, '
            .. 'induration, impaction, transfixion, compression, fusion, fragmentation, gravitation, distortion)')
        return false
    end
    if n and (n < 2 or n > 5) then h.log('Steps: 2 to 5') return false end
    if n then S.mages.chain_steps = n end
    S.mages.chain = name == 'off' and '' or name
    S.mages.immanence = name ~= 'off'
    if name == 'off' then h.log('Immanence skillchains off') return true end
    local list, res = mages.plan(S.mages.chain_steps or 2, name)
    if not list then
        h.log(('Immanence skillchain: no %d-step chain ends on %s - try another number of steps'):format(S.mages.chain_steps or 2, name))
        return true
    end
    local names = {}
    for i, e in ipairs(list) do names[i] = (NUKE[e] or HELIX[e]) end
    h.log(('Immanence skillchain: %s in %d steps (%s)'):format(res, #list, table.concat(names, ' > ')))
    return true
end

function mages.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return mages
