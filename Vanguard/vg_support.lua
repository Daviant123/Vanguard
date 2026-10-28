--[[
Vanguard: Corsair, Geomancer and Bard know-how from the community job guides (round 10, 2026-10-15).

  COR  Smarter Double-Up   stop on the lucky number or 11; Snake Eye at 10 (-> 11), one short of lucky, or on the
                           unlucky number; otherwise Double-Up only while the bust chance is at most cor.risk %
                           (0 = only up to 5, never a bust; 6 = 17%, 7 = 33%, 8 = 50% ...); Fold a bust.
       Roll range          rolls wait until the leader is within cor.range yalms (8; 16 with Luzaf's Ring) and the
                           Corsair walks over to roll.
       Roll sets           //vg rolls melee|magic|accuracy|tank|refresh|exp|<roll>,<roll>  (on the leader: sent to the
                           Corsair alts)
  GEO  Hate list first     a Geo debuff (Geo-Frailty, Malaise ...) only works once the GEO is on the mob's hate list:
                           Dia II / Dia first.
       Entrust auto        //vg set geo.entrust auto: Indi-Haste (or Indi-Fury) entrusted to the leader.
       Radial Arcana       also when 2+ party members are under geo.party_mp % MP (not only the GEO itself).
  BRD  NiTro               in a fight with songs due, Nightingale + Troubadour (+ Marcato), then every song is sung
                           fresh; songs sung under Troubadour count as lasting twice as long.
       Pianissimo          //vg pianissimo <song> > <name>[|<name>]   single-target songs per member
                           (Mage's Ballad III > CharB|CharC, Sentinel's Scherzo > CharA);  //vg pianissimo clear
       Horde Lullaby       with //vg sleep on, 2+ extra mobs get an AoE sleep (vg_mages).

Normal game commands only (/ja, /ma).
]]

local util = require('vg_util')
local jobs = require('vg_jobs')

local support = {}
local S, state, h

local function clock() return os.clock() end

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
    if ja and util.ability_ready(ja) and not h.recently('ja:' .. ja.en .. ':<me>', 3) then return ja end
    return nil
end

------------------------------------------------------------------------
-- COR: Double-Up
------------------------------------------------------------------------
-- Bust chance (%) when doubling up from this total.
local BUST = { [6] = 17, [7] = 33, [8] = 50, [9] = 67, [10] = 83 }
support.BUST = BUST

-- What to do with a roll total: 'stop', 'snake' (Snake Eye then Double-Up) or 'double'.
function support.roll_choice(name, value, snake_ready, risk)
    local t = jobs.lucky[name] or {}
    local lucky, unlucky = t[1], t[2]
    if value == lucky or value >= 11 then return 'stop' end
    if snake_ready and (value == 10 or value == unlucky or (lucky and value == lucky - 1)) then return 'snake' end
    if (BUST[value] or 0) <= (tonumber(risk) or 0) then return 'double' end
    return 'stop'
end

function support.double_up(ctx, engine)
    local p = ctx.player
    -- Busted: Fold takes the bust off.
    if util.has_buff(p.buffs, 309) and S.cor.fold then
        local fold = ja_ready('Fold', p)
        if fold then h.log('Bust: Fold') return h.use_ja(fold, '<me>') end
    end
    local r = engine.last_roll
    if not r or clock() - r.time > 40 then return false end
    if not util.has_buff(p.buffs, 308) then return false end           -- Double-Up Chance
    local du = has_ja('Double-Up')
    if not du or not util.ability_ready(du) or ctx.recently('ja:Double-Up:<me>', 3) then return false end
    local snake = S.cor.snake_eye and not util.has_buff(p.buffs, 357) and ja_ready('Snake Eye', p)
    local choice = util.has_buff(p.buffs, 357) and 'double' or support.roll_choice(r.name, r.value, snake ~= nil, S.cor.risk)
    if choice == 'snake' then
        h.log(('Snake Eye (%s at %d)'):format(r.name, r.value))
        return h.use_ja(snake, '<me>')
    elseif choice == 'double' then
        h.log(('Double-Up (%s at %d)'):format(r.name, r.value))
        engine.last_roll = nil
        return h.use_ja(du, '<me>')
    end
    engine.last_roll = nil                                         -- keep it
    return false
end

-- Rolls only reach party members within cor.range: is the leader close enough?
function support.roll_in_range(player)
    -- a Corsair that farms is where the fighting is: it rolls where it stands (it waited for a far-off leader, or
    -- walked over to them and pulled against the farming - his report 2026-10-28: "daviant was not using cor rolls")
    if S.modules.farm then return true end
    local l = h.leader_mob(player)
    if not l then return true end
    return util.dist(l) <= (tonumber(S.cor.range) or 8)
end

function support.roll_approach(player)
    if S.farm and S.farm.stay then return end                     -- (DO NOT MOVE)
    local l = h.leader_mob(player)
    local me = windower.ffxi.get_mob_by_target('me')
    if not l or not me or util.dist(l) > 40 then return end
    if not h.recently('roll_walk', 10) then h.mark('roll_walk') h.log('Walking to ' .. l.name .. ' to roll') end
    h.run_toward(me, l)
    state.roll_walk = true
end

-- Called after movement: stop once in range.
function support.roll_walk_tick(player)
    if state.roll_walk and support.roll_in_range(player) then
        state.roll_walk = false
        local l = h.leader_mob(player)
        if not l or util.dist(l) <= (tonumber(S.cor.range) or 8) - 1 then h.stop_running() end
    end
end

local ROLL_SETS = {
    melee    = { 'roll_samurai', 'roll_chaos' },
    magic    = { 'roll_wizards', 'roll_warlocks' },
    accuracy = { 'roll_hunters', 'roll_chaos' },
    tank     = { 'roll_fighters', 'roll_samurai' },
    crit     = { 'roll_rogues', 'roll_chaos' },
    refresh  = { 'roll_evokers', 'roll_wizards' },
    exp      = { 'roll_corsairs', 'roll_chaos' },
    fastcast = { 'roll_casters', 'roll_wizards' },
}
support.ROLL_SETS = ROLL_SETS

local function roll_id(word)
    word = util.trim(word):lower():gsub("'", ''):gsub(' roll$', '')
    for _, a in ipairs(jobs.COR.actions) do
        if a.kind == 'roll' and (a.id == 'roll_' .. word or a.id == 'roll_' .. word .. 's') then return a.id end
    end
end

-- Returns the list of roll action ids for a set name or "Roll,Roll".
function support.roll_set(arg)
    arg = (arg or ''):lower()
    if ROLL_SETS[arg] then return ROLL_SETS[arg] end
    local out = {}
    for _, w in ipairs(util.split(arg, ',')) do
        local id = roll_id(w)
        if id then out[#out + 1] = id end
    end
    return #out > 0 and out or nil
end

-- //vg rolls <set>. On a Corsair: switch the roll actions. Elsewhere: tell the Corsair alts.
function support.rolls(player, arg, apply)
    local set = support.roll_set(arg)
    if not set then
        h.log('Usage: //vg rolls melee|magic|accuracy|tank|crit|refresh|exp|fastcast or e.g. //vg rolls chaos,samurai')
        return false
    end
    if player.main_job ~= 'COR' then
        windower.send_ipc_message(('vg_rolls %s %s'):format(player.name, arg:gsub('%s', '')))
        h.log('Rolls sent to the Corsairs: ' .. arg)
        return true
    end
    apply(set)
    return true
end

function support.on_rolls(player, from, arg, apply)
    if player.main_job ~= 'COR' or S.leader == '' or from:lower() ~= S.leader:lower() then return end
    local set = support.roll_set(arg)
    if set then apply(set) end
end

------------------------------------------------------------------------
-- GEO
------------------------------------------------------------------------
-- Before a Geo debuff on the battle target: get on its hate list (Dia II / Dia).
function support.geo_hate(player, spell, mob)
    if not S.geo.hate_first or not spell or not mob then return false end
    if not util.targets(spell, 'Enemy') or util.targets(spell, 'Self') then return false end   -- only enemy-target Geo spells
    state.geo_hate = state.geo_hate or {}
    if state.geo_hate[mob.id] then return false end
    if util.dist(mob) > 21.5 then return false end               -- out of range: not "nothing to cast", just wait
    for _, name in ipairs({ 'Dia II', 'Dia', 'Stone' }) do
        if h.try_cast(name, '<bt>', 'hate list before ' .. spell.en, player) then
            state.geo_hate[mob.id] = true
            return true
        end
    end
    state.geo_hate[mob.id] = true                                -- nothing to cast: don't hold the bubble back
    return false
end

-- Where the luopan goes for this Geo spell: an enemy bubble always on the battle target ('bt'); a party bubble on the
-- member picked, or - with "Enemy" picked (the default) - on the leader if near, else on me. Picking Geo-Regen with
-- the target left on "Enemy" (or Geo-Frailty on "Me") had the game refuse it every few seconds (2026-10-19 GEO round).
function support.geo_place(player, spell)
    local tgt = S.geo.geo_target or 'bt'
    if spell and util.targets(spell, 'Enemy') then return 'bt' end
    if tgt == 'me' or tgt == '' then return 'me' end
    if tgt ~= 'bt' then return tgt end
    local lead = S.leader ~= '' and S.leader:lower() ~= player.name:lower() and S.leader
    if lead then
        for _, m in ipairs(h.party_members(20)) do if m.name:lower() == lead:lower() then return m.name end end
    end
    return 'me'
end

-- What the Geomancy tab shows (2026-10-19 GEO round): the luopan (which Geo spell, its HP, how far from the mob it's
-- for and whether that's within its ~6' reach), my Indi, and who carries the entrusted Indi.
function support.geo_info(player)
    local out = {}
    local pet = windower.ffxi.get_mob_by_target('pet')
    local last = state.geo_last
    if pet then
        local l = { name = last and last.name or 'luopan', hpp = pet.hpp or 100 }
        local bt = h.battle_target()
        if bt and last and util.spell(last.name) and util.targets(util.spell(last.name), 'Enemy') then
            local dx, dy = pet.x - bt.x, pet.y - bt.y
            l.dist = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
            l.mob = bt.name
        end
        out.luopan = l
    end
    local on = state.indi_on or {}
    if util.has_buff(player.buffs, 612) and on.me then out.indi = on.me end
    for _, m in ipairs(h.party_members(30)) do
        local was = on[m.name:lower()]
        if m.name ~= player.name and was and util.has_buff(h.buffs_of(m, player) or {}, 612) then
            out.entrust = { name = was, who = m.name }
        end
    end
    return out
end

-- Is the luopan out of use? Its bubble reaches about 6' around it (bg-wiki), and it stays where it was put down. It
-- used to be recalled only 15' from the fight, so after a mob died the next one 7-15' away sat outside the bubble the
-- whole fight, and a bubble on a member who walked off was never moved (2026-10-18). Returns why, or nil.
local REACH = 7                                                  -- 6' plus a little for the mob's size
function support.luopan_off(player, pet, bt)
    local last = state.geo_last
    if not last or clock() - last.at < 8 then return nil end     -- just put down
    local spell = util.spell(last.name)
    if not spell then return nil end
    local function d(a, b) local dx, dy = a.x - b.x, a.y - b.y return math.sqrt(dx * dx + dy * dy) end
    if S.geo.geo ~= '' and S.geo.geo:lower() ~= last.name:lower() and h.party_engaged(player) then
        return 'changing it to ' .. S.geo.geo
    end
    if util.targets(spell, 'Enemy') then
        if not bt then return nil end                            -- between fights: the next mob may come to it
        local dist = d(pet, bt)
        if dist > (tonumber(S.geo.full_circle_range) or 15) then return 'luopan too far from the target' end
        if bt.id ~= last.target and dist > REACH then return ("the new mob is %d' from the luopan"):format(math.floor(dist)) end
        return nil
    end
    -- a bubble for the party, put down on me or a member: moved when that one is out of its reach
    local who = support.geo_place(player, spell)
    local m = who == 'me' and windower.ffxi.get_mob_by_target('me') or windower.ffxi.get_mob_by_name(who)
    if m and d(pet, m) > REACH + 1 and h.party_engaged(player) then
        return ("%s is %d' from the luopan"):format(m.name, math.floor(d(pet, m)))
    end
    return nil
end

-- Somebody on our side hit the mob (cure-hate also counts, but a hit or enfeeble from us is what we see).
function support.note_hate(act, player)
    if act.actor_id ~= player.id then return end
    state.geo_hate = state.geo_hate or {}
    for _, t in ipairs(act.targets or {}) do
        local m = windower.ffxi.get_mob_by_id(t.id)
        if m and m.is_npc and m.spawn_type == 16 then state.geo_hate[t.id] = true end
    end
end

-- "auto" entrust: Indi-Haste (or Indi-Fury) on the leader.
function support.entrust_setting(player)
    local e = S.geo.entrust or ''
    if e:lower() ~= 'auto' then return e end
    if S.leader == '' or S.leader:lower() == player.name:lower() then return '' end
    for _, name in ipairs({ 'Indi-Haste', 'Indi-Fury', 'Indi-Precision' }) do
        local s = util.spell(name)
        if s and util.can_cast(s, player) then return name .. '>' .. S.leader end
    end
    return ''
end

-- Radial Arcana when the party's casters run dry.
function support.radial(player)
    if player.main_job ~= 'GEO' or not windower.ffxi.get_mob_by_target('pet') then return false end
    local limit = tonumber(S.geo.party_mp) or 0
    if limit <= 0 then return false end
    local low = 0
    for _, m in ipairs(h.party_members(20)) do
        if m.name ~= player.name and m.hpp > 0 and m.mpp and m.mpp < limit then low = low + 1 end
    end
    if low < 2 then return false end
    local ja = ja_ready('Radial Arcana', player)
    if ja then h.log(('Radial Arcana: %d members low on MP'):format(low)) return h.use_ja(ja, '<me>') end
    return false
end

------------------------------------------------------------------------
-- BRD
------------------------------------------------------------------------
-- When NiTro may go up: in a fight (songs.nitro_when 'fight', the default) or any time ('always' - also before the pull,
-- as soon as the bard starts; he expected NiTro when he started his bard before a fight, 2026-10-19)
local function nitro_time(player)
    return S.songs.nitro_when == 'always' or h.party_engaged(player)
end

-- NiTro: both abilities ready, a fight, songs set, at least one song due soon.
function support.nitro(player, songs_due)
    if not S.songs.nitro or player.main_job ~= 'BRD' or S.songs.list == '' or not nitro_time(player) then return false end
    local p = player
    local night, troub = util.has_buff(p.buffs, 347), util.has_buff(p.buffs, 348)
    -- Under way: Troubadour after Nightingale, then Marcato, before any song.
    if state.nitro_until and clock() < state.nitro_until then
        if night and not troub then
            local t = ja_ready('Troubadour', p)
            if t then
                state.redo_at = clock()                          -- every song sung before this is sung again (vg_bard)
                return h.use_ja(t, '<me>')
            end
            return true
        end
        if night and troub then
            state.nitro_until = nil                              -- Marcato comes right before its song (vg_bard)
            return false
        end
        return true                                              -- waiting for Nightingale to show
    end
    if not songs_due or night then return false end
    local n, t = has_ja('Nightingale'), has_ja('Troubadour')
    if not n or not t or not util.ability_ready(n) or not util.ability_ready(t) or h.amnesia(p) then return false end
    if h.recently('ja:Nightingale:<me>', 3) then return false end
    state.nitro_until = clock() + 6
    h.log('NiTro: Nightingale + Troubadour, then all songs fresh')
    return h.use_ja(n, '<me>')
end

-- Seconds until Nightingale and Troubadour are both ready (0 = now); nil when NiTro isn't wanted / possible now
-- (off, not a bard, no fight, the abilities not learned, Amnesia, Troubadour already up).
function support.nitro_wait(player)
    if not S.songs.nitro or player.main_job ~= 'BRD' or S.songs.list == '' or not nitro_time(player) then return nil end
    if util.has_buff(player.buffs, 348) or h.amnesia(player) then return nil end
    local n, t = has_ja('Nightingale'), has_ja('Troubadour')
    if not n or not t then return nil end
    local recasts = windower.ffxi.get_ability_recasts() or {}
    return math.max(tonumber(recasts[n.recast_id]) or 0, tonumber(recasts[t.recast_id]) or 0)
end

-- Pianissimo songs: "Song>Name|Name,Song>Name"
function support.pianissimo(player)
    if player.main_job ~= 'BRD' or (S.songs.pianissimo or '') == '' or h.silenced(player) then return false end
    if S.songs.when == 'engaged' and not h.party_engaged(player) then return false end
    local present = {}
    for _, m in ipairs(h.party_members(20)) do present[m.name:lower()] = m end
    local bard = require('vg_bard')
    for _, entry in ipairs(util.split(S.songs.pianissimo, ',')) do
        local song, who = entry:match('^(.-)%s*>%s*(.+)$')
        local spell = song and util.spell(song)
        if spell and util.can_cast(spell, player) then
            for _, name in ipairs(util.split(who, '|')) do
                local m = present[util.trim(name):lower()]
                if m and m.name ~= player.name and m.hpp > 0 and bard.member_needs(spell, m.name, player, h.buffs_of(m, player))
                    and util.spell_ready(spell, player) then
                    if util.has_buff(player.buffs, 409) then
                        bard.member_cast(spell, m.name)
                        return h.cast(spell, m.name, 'Pianissimo ' .. spell.en .. ' -> ' .. m.name)
                    end
                    local pj = ja_ready('Pianissimo', player)
                    if pj then return h.use_ja(pj, '<me>') end
                    return false
                end
            end
        end
    end
    return false
end

-- //vg pianissimo <song> > <name>[|<name>]  |  clear  |  (nothing: show)
function support.set_pianissimo(rest)
    rest = util.trim(rest or '')
    if rest == '' then
        h.log('Pianissimo songs: ' .. ((S.songs.pianissimo or '') ~= '' and S.songs.pianissimo or 'none') ..
            '   (//vg pianissimo Mage\'s Ballad III > CharB|CharC)')
        return false
    end
    if rest:lower() == 'clear' or rest:lower() == 'off' then
        S.songs.pianissimo = ''
        h.log('Pianissimo songs cleared')
        return true
    end
    local song, who = rest:match('^(.-)%s*>%s*(.+)$')
    local spell = song and util.spell(song)
    if not spell or spell.type ~= 'BardSong' then
        h.log('Usage: //vg pianissimo <song> > <name>[|<name>]   e.g. //vg pianissimo Mage\'s Ballad III > CharB|CharC')
        return false
    end
    local entry = spell.en .. '>' .. who:gsub('%s*|%s*', '|')
    local list = {}
    for _, e in ipairs(util.split(S.songs.pianissimo or '', ',')) do
        if not e:lower():find(spell.en:lower() .. '>', 1, true) then list[#list + 1] = e end
    end
    list[#list + 1] = entry
    S.songs.pianissimo = table.concat(list, ',')
    h.log('Pianissimo: ' .. entry)
    return true
end

function support.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return support
