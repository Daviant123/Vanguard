--[[
Vanguard: Sortie (his request 2026-11-25, after looking at the SortiePlus addon - ideas only, no code; RESEARCH.md
"Sortie addons"). Only in Sortie (Outer Ra'Kaznar [U2] / [U3], zones 133 / 189), only from what the game shows:
the chat log and the monsters in view. No packets are sent.

  Sector        Known by itself: the monster being fought or targeted (every sector's foes share a name: Abject A,
                Biune B, Cachaemic C, Demisang D, Esurient E, Fetid F, Gyvewrapped G, Haughty H; and the bosses), or
                a warp ("Warping via ... to Bitzer #D", "... Diaphanous Device ... - 2"). With the Scholar's Sortie
                setup (//vg sortie) the Scholar changes with it: A magic killing blow, D 4-step chains, else 2-step.
  Boss procs    Degei (D) and Aita (H) turn weak to one element after each elemental TP move (bg-wiki Degei / Aita):
                Flaming Kick -> Water, Flashflood -> Thunder, Icy Grasp -> Fire, Eroding Flesh -> Wind,
                Fulminous Smash -> Earth. Any magic of that element procs it (0 damage is enough); without a proc
                Vivisection wipes the party. So: a quick nuke of that element (anyone who can cast it), the
                Scholar's chain / Storm / bursts follow it, no Immanence skillchains on them (a skillchain or the
                wrong element heals them back) and bursts only of the proc element.
  Boss timer    Skomora / Triboulex: Setting the Stage, Degei: Vivisection - 180 s; Aita: Vivisection - 185 s,
                counted from the party's claim; a warning 30 s before.
  Run           chest status reports ("#A treasure coffer status report: 1/8 #?: 0/1."), shards / metals
                ("Ra'Kaznar shard #A"), bosses defeated, Gallimaufry gained. Shown in the app's Sortie box.
]]

local util = require('vg_util')

local sortie = {}
local S, state, h

local function clock() return os.clock() end

local ZONES = { [133] = true, [189] = true }
local PREFIX = { abject = 'A', biune = 'B', cachaemic = 'C', demisang = 'D', esurient = 'E', fetid = 'F',
                 gyvewrapped = 'G', haughty = 'H' }
local BOSS = { Ghatjot = 'A', Leshonn = 'B', Skomora = 'C', Degei = 'D', Dhartok = 'E', Gartell = 'F', Triboulex = 'G',
               Aita = 'H' }
local TIMER = { Skomora = { 180, 'Setting the Stage' }, Triboulex = { 180, 'Setting the Stage' },
                Degei = { 180, 'Vivisection' }, Aita = { 185, 'Vivisection' } }
local PROC_BOSS = { Degei = true, Aita = true }
local COUNTER = { ['Flaming Kick'] = 'water', ['Flashflood'] = 'thunder', ['Icy Grasp'] = 'fire',
                  ['Eroding Flesh'] = 'wind', ['Fulminous Smash'] = 'earth' }
sortie.COUNTER, sortie.BOSS = COUNTER, BOSS
local DEVICE = { ['1'] = 'A', ['2'] = 'B', ['3'] = 'C', ['4'] = 'D' }

local function st()
    state.sortie = state.sortie or { coffer = {}, items = {}, killed = {}, galli = nil }
    return state.sortie
end

function sortie.active()
    local info = windower.ffxi.get_info()
    return info and ZONES[info.zone] or false
end

-- the sector a monster belongs to (its first word, or a boss name)
function sortie.sector_of(name)
    if not name then return nil end
    if BOSS[name] then return BOSS[name] end
    local first = name:match('^(%a+)')
    return first and PREFIX[first:lower()] or nil
end

function sortie.set_sector(sec, why)
    local s = st()
    if not sec or s.sector == sec then return end
    s.sector, s.sector_t = sec, clock()
    h.log(('Sortie: sector %s (%s)'):format(sec, why))
    if S.mages and S.mages.sortie_auto then require('vg_mages').sector_mode(sec) end
end

------------------------------------------------------------------------
-- Every tick: the sector from the fight, the boss timer
------------------------------------------------------------------------
function sortie.tick(player)
    if not sortie.active() then return end
    local s = st()
    local bt = h.battle_target()
    local t = windower.ffxi.get_mob_by_target('t')
    local mob = bt or (t and t.is_npc and t.spawn_type == 16 and t) or nil
    if mob then sortie.set_sector(sortie.sector_of(mob.name), mob.name) end
    -- boss timer: from the party's claim
    if bt and TIMER[bt.name] and (bt.claim_id or 0) ~= 0 and (not s.boss or s.boss.id ~= bt.id) then
        s.boss = { id = bt.id, name = bt.name, start = clock(), warned = false }
        h.log(('Sortie: %s claimed - %s in %d s'):format(bt.name, TIMER[bt.name][2], TIMER[bt.name][1]))
    end
    local b = s.boss
    if b then
        local m = windower.ffxi.get_mob_by_id(b.id)
        if not m or (m.hpp or 0) <= 0 or m.status == 2 or m.status == 3 then
            s.boss = nil
        else
            local left = TIMER[b.name][1] - (clock() - b.start)
            if left <= 30 and not b.warned then
                b.warned = true
                h.log(('Sortie: %s - %s in 30 s!'):format(b.name, TIMER[b.name][2]))
            end
            if left < -20 then b.start = clock() b.warned = false end      -- (it comes round again)
        end
    end
end

------------------------------------------------------------------------
-- The chat log
------------------------------------------------------------------------
function sortie.on_text(original)
    if not sortie.active() then return end
    local text = (original or ''):gsub('[%z\1-\31\127]', ''):gsub('[\128-\255]+', ' ')
    local s = st()
    if text:find('Warping via', 1, true) then
        local sec = text:match('to Bitzer #(%u)') or text:match('to Gadget #(%u)')
        local dev = text:match('Diaphanous Device .-%- (%d+)')
        sec = sec or (dev and DEVICE[dev])
        if sec then sortie.set_sector(sec, 'warp') end
    end
    local cs, cn, ct, qn, qt = text:match('#(%u) treasure coffer status report: (%d+)/(%d+) #%?: (%d+)/(%d+)')
    if cs then s.coffer[cs] = { n = tonumber(cn), total = tonumber(ct), q = tonumber(qn), qt = tonumber(qt) } end
    local kind, isec = text:match("Ra'Kaznar (%a+) #(%u)")
    if kind then s.items[kind:lower() .. ' ' .. isec] = true end
    local got, total = text:match('received (%d+) gallimaufry for a total of (%d+)')
    if got then
        s.galli = s.galli or { first = tonumber(total) - tonumber(got), gained = 0 }
        s.galli.gained, s.galli.total = tonumber(total) - s.galli.first, tonumber(total)
    end
    for name in pairs(BOSS) do
        if text:find('defeats ' .. name, 1, true) then
            s.killed[name] = true
            if s.boss and s.boss.name == name then s.boss = nil end
            if s.proc and s.proc.boss == name then s.proc = nil end
        end
    end
    -- Degei / Aita: "Degei uses Flaming Kick." -> water (also from the action itself, sortie.on_move)
    local who, move = text:match('(%a+) uses ([%a\' ]+)')
    if who then sortie.on_move(who, (move:gsub('%s+$', ''))) end
end

-- a monster's TP move (chat line or action packet 0x028, category 11)
function sortie.on_move(who, move)
    if not (who and move and PROC_BOSS[who]) or not sortie.active() then return end
    local s = st()
    if move == 'Vivisection' then
        s.proc = nil
        if s.boss and s.boss.name == who then s.boss.start, s.boss.warned = clock(), false end
    elseif COUNTER[move] then
        local p = s.proc
        if p and p.boss == who and p.move == move and clock() - p.t < 3 then return end    -- (seen twice: chat + action)
        s.proc = { boss = who, el = COUNTER[move], move = move, t = clock(), tries = 0 }
        h.log(('Sortie: %s used %s - %s magic procs it'):format(who, move, COUNTER[move]))
    end
end

------------------------------------------------------------------------
-- For the mages
------------------------------------------------------------------------
local function proc_for(mob)
    local s = state.sortie
    local p = s and s.proc
    if not (p and mob and mob.name == p.boss) then return nil end
    if clock() - p.t > 180 then s.proc = nil return nil end
    return p
end

-- the element a Degei / Aita is weak to right now (nil: anything else / not known)
function sortie.element_for(mob)
    if not sortie.active() then return nil end
    local p = proc_for(mob)
    return p and p.el or nil
end

-- no Immanence skillchains on Degei / Aita (a skillchain heals them back)
function sortie.no_chain(mob)
    return mob and PROC_BOSS[mob.name] and sortie.active() or false
end

-- bursts on Degei / Aita: only the proc element
function sortie.only_element(mob)
    if not (mob and PROC_BOSS[mob.name] and sortie.active()) then return nil end
    local p = proc_for(mob)
    return p and p.el or 'none'
end

-- the proc itself: a quick single-target nuke of that element (any job that can cast one)
function sortie.proc(player)
    if not sortie.active() or (S.mages and S.mages.sortie_procs == false) or h.silenced(player) then return false end
    local bt = h.battle_target()
    local p = proc_for(bt)
    if not p or p.done or p.tries >= 3 or util.dist(bt) > 21 then return false end
    if h.recently('sortie_proc', 6) then return false end
    local mg = require('vg_mages')
    local s = mg.quick_nuke and mg.quick_nuke(player, p.el, ('%s proc: %s after %s'):format(bt.name, p.el, p.move))
    if s then
        h.mark('sortie_proc')
        p.tries = p.tries + 1
        return true
    end
    return false
end

-- a cast of the proc element landed on the boss (vg action handler): done until its next TP move
function sortie.on_hit(target_id, spell)
    local s = state.sortie
    local p = s and s.proc
    if not (p and spell and spell.element) then return end
    local m = windower.ffxi.get_mob_by_id(target_id)
    if not (m and m.name == p.boss) then return end
    local EL = { [0] = 'fire', [1] = 'ice', [2] = 'wind', [3] = 'earth', [4] = 'thunder', [5] = 'water', [6] = 'light', [7] = 'dark' }
    if EL[spell.element] == p.el then p.done = true end
end

-- for the app's Sortie box
function sortie.snap()
    if not sortie.active() then return nil end
    local s = st()
    local b = s.boss
    local p = s.proc
    local killed = {}
    for n in pairs(s.killed) do killed[#killed + 1] = n end
    table.sort(killed)
    local items = {}
    for k in pairs(s.items) do items[#items + 1] = k end
    table.sort(items)
    return {
        sector = s.sector or '',
        boss = b and b.name or nil,
        left = b and math.max(0, math.floor(TIMER[b.name][1] - (clock() - b.start))) or nil,
        what = b and TIMER[b.name][2] or nil,
        proc = p and (clock() - p.t < 180) and { boss = p.boss, el = p.el, move = p.move, done = p.done == true } or nil,
        coffer = s.coffer, items = items, killed = killed,
        galli = s.galli and s.galli.gained or 0,
        auto = S.mages and S.mages.sortie_auto or false,
    }
end

function sortie.on_zone(new_id)
    if not ZONES[new_id] then state.sortie = nil end       -- (a new run starts clean)
end

function sortie.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return sortie
