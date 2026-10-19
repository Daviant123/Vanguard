_addon.name = 'Vanguard'
_addon.author = 'Daviant'
_addon.version = '0.82.4'
_addon.commands = {'vanguard', 'vg'}

--[[
Vanguard - multibox party assistant for Windower 4.

Load on every character:   //lua load vanguard
Turn on / off:             //vg on   |  //vg off
Help:                      //vg help

Modules (each can be toggled per character):
  follow, assist, heal, raise, cleanse, buffs, ws, sc, burst,
  songs, geo, debuff, dispel, triggers

Everything is configured in data/settings.xml (one section per character)
or live with //vg set <section>.<key> <value>, and can be driven from the
Vanguard Control desktop app.
]]

require('tables')
require('strings')
require('sets')
require('pack')
local config = require('config')
local res = require('resources')

local util = require('vg_util')
local triggers = require('vg_triggers')
local bridge = require('vg_bridge')
local jobs = require('vg_jobs')
local engine = require('vg_actions')
local menu = require('vg_menu')
local alts = require('vg_alts')
local party = require('vg_party')
local hud = require('vg_hud')
local travel = require('vg_travel')
local combat = require('vg_combat')
local team = require('vg_team')
local share = require('vg_share')
local safety = require('vg_safety')
local store = require('vg_store')
local mages = require('vg_mages')
local support = require('vg_support')
local update = require('vg_update')
local link = require('vg_link')
local strat = require('vg_strat')
local bard = require('vg_bard')
local stats = require('vg_stats')
local crash = require('vg_crash')
local warp = require('vg_warp')
local finish = require('vg_finish')
local farm = require('vg_farm')
local trials = require('vg_trials')
crash.init(bridge)
-- Every event handler below runs guarded: an error becomes a crash report instead of red text (vg_crash).
do
    local raw_register = windower.register_event
    windower.register_event = function(ev, fn) return raw_register(ev, crash.guard('event ' .. ev, fn)) end
end
local quick = require('vg_quick')

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local defaults = {
    enabled = false,
    autostart = false,
    resume_until = 0,       -- set when unloaded while running: a reload within 90 s carries on
    hotkeys = '',            -- quick-button hotkeys bound in this game window (vg_quick, set from the app)       -- start by itself when Vanguard loads (login / reload); off = wait for Start
    leader = '',
    tick = 0.25,
    modules = {
        follow = false, assist = false, heal = false, raise = false, cleanse = false,
        buffs = false, ws = false, sc = false, burst = false, songs = false,
        geo = false, debuff = false, dispel = false, triggers = false,
        rest = false, mana = false, trusts = false, farm = false, actions = false,
    },
    -- Saved per-job setup: role, weapon skill and ability on/off choices (managed automatically).
    profiles = {},
    -- Saved per-job menu choices from the panel (buff grid, songs, geo, enfeebles, modules).
    menus = {},
    pause_on_zone = true,   -- stop the bot on a zone change (his request 2026-10-17: "when it changes zones i want you to stop the bot")
    stop_on_job = true,     -- ...and when the job or sub job changes (same request)
    -- formation: spread (fan behind the leader), line (single file) or off (plain follow)
    follow = { distance = 2.5, max_distance = 40, formation = 'spread', trail = true },
    party = { accept = true },          -- accept party invites from the leader / other Vanguard characters
    -- disengage: stop when the leader stops; defend: fight back when attacked while the leader is idle
    assist = { engage = true, approach = true, melee_range = 3.0, engage_range = 25, disengage = true, defend = true,
               autotarget = true },
    -- priority = names healed first at a higher threshold (tanks). wake_sleep = cure sleeping members.
    -- tiers: HP missing before each Cure tier is used (0 = never use it), like CurePlease's cure thresholds
    heal = { cure_at = 75, curaga_at = 70, curaga_count = 3, range = 20,
             tiers = 'Cure VI:1300,Cure V:1000,Cure IV:650,Cure III:350,Cure II:170,Cure:70',
             curagas = 'Curaga V,Curaga IV,Curaga III,Curaga II,Curaga',   -- Curaga tiers it may use
             priority = '', priority_at = 85, wake_sleep = true,
             ignore = '', curaga = true },
    -- Statuses NOT to remove (comma list of status names).
    cleanse = { skip = '' },
    -- Rest (/heal) when idle and low; stand back up when recovered.
    rest = { hp_low = 40, hp_high = 95, mp_low = 25, mp_high = 95 },
    -- Sublimation upkeep and Convert.
    -- reserve: below this MP% only cures / Raise / status removal are cast (0 = off) - MP saved for healing
    mana = { sublimation = true, sublimation_mpp = 70, convert_mpp = 15, reserve = 0 },
    -- Summon trusts (spell names) until the party has party_size members.
    trusts = { list = '', party_size = 5 },
    -- Farming: target names (partial match), ignore list, claim filter (unclaimed|party|any),
    -- detection range/height, pull command after engaging, and a recorded route.
    -- farming (vg_farm): mode list|aggro|any; area camp|route; camp "x:y:z" in camp_zone; wait for the party before
    -- pulling (HP / MP %, within yalms); stop when the inventory is full / after stop_kills kills (0 = never)
    farm = { targets = '', ignore = '', claim = 'unclaimed', aggro_first = true, range = 20,
             height = 5, approach = true, pull_cmd = '', route = '', loop = true,
             mode = 'list', area = 'camp', camp = '', camp_zone = 0, back_to_camp = true,
             wait_party = true, wait_hp = 70, wait_mp = 40, wait_near = 20, stop_full = true, stop_kills = 0,
             item = '', item_goal = 0,     -- farming for an item: stop when item_goal of it are in the inventory
             pull_back = false,           -- bring each mob back to camp before fighting (the others wait there)
             prefer_best = false,         -- prefer the mob kind that pays best per minute (the mob report)
             keep_chain = false,          -- XP / CP chains: while one runs, wait only for emergencies (HP 40%, MP 15%)
             stop_mins = 0, when_done = 'stay',   -- stop after N minutes (0 = no); then stay | warp | logout (everyone)
             skip_strong = true, strong = '',     -- mobs that nearly KO'd the farmer / took 3+ min twice: set aside
             preset = '',                         -- the last one-click preset (party | items | safe | clear)
             th = false,                          -- Treasure Hunter: GearSwap TreasureMode Tag while farming
             rotate = false,                      -- a spot dry for 3 min: move on to the next saved spot in the zone
             rest_idle = true,                    -- rest at camp while there's nothing to fight (up when a mob comes)
             check = false, skip_weak = false, skip_tough = false,  -- /check each new kind; skip Too Weak / Incredibly Tough + NMs
             make_room = false,                   -- bags nearly full: ask Steward to tidy them (//stw sort bags)
             stop_trial = true,                   -- a Magian trial it's farming for is done: stop
             rezone = false,                      -- zoned out while farming: back in the same zone within 15 min -> farm again
             time_alert = true,                   -- ring when the game says Abyssea (Visitant) time is running out
             stop_level = 0,                      -- stop when this character's main job reaches this level (0 = no)
             widen = 0,                           -- quiet spot: search 10 yalms further every 30 s, up to this (0 = off)
             polite = true,                       -- leave unclaimed mobs another player is standing next to
             hotkey = '',                         -- a key that starts / stops farming from the game window (^f9 ...)
             emergency = '', emergency_hp = 25,   -- under this HP % in a fight: this item / ability (from a menu)
             watch = '',                          -- rare drop alert: items that ring the app's Alarms when they drop
             packs = true, pack_range = 8, pack_strict = false },
    farmspots = { s0 = '' },
    trials = { t0 = '' }, trial_assist = '',   -- Magian trials (vg_trials): t1 = "kind|goal|ws|mobs|count"      -- saved farm spots (vg_farm): s1, s2, ... = "name|zone|field=value|..." 
    -- "Spell>target" pairs. target = me or a party member name. "ja:" prefix = job ability.
    buffs = { list = '' },
    -- finish*: the weapon skill that lands the kill (vg_finish): at mob HP% finish_at, saving TP, others stop attacking
    ws = { name = '', tp = 1000, min_mob_hpp = 1, max_range = 6,
           finish = '', finish_at = 0, learned = '', finish_trial_only = true, finish_save = true, finish_others = true, finish_wait = false },
    -- Ordered chain steps "Character:Weapon Skill". Each character only fires its own steps.
    sc = { steps = '', open_tp = 1000, window_min = 3, window_max = 8 },
    -- "Element:Spell|Fallback|Fallback" pairs.
    burst = {
        spells = 'Fire:Fire V|Fire IV|Fire III,Ice:Blizzard V|Blizzard IV|Blizzard III,' ..
                 'Wind:Aero V|Aero IV|Aero III,Earth:Stone V|Stone IV|Stone III,' ..
                 'Lightning:Thunder V|Thunder IV|Thunder III,Water:Water V|Water IV|Water III,' ..
                 'Light:Banish III|Banish II,Dark:Aspir III|Aspir II|Drain',
        window = 8,
    },
    -- nitro: Nightingale + Troubadour (+ Marcato) then all songs; pianissimo = "Song>Name|Name,..." single-target songs
    -- Bard (vg_bard, after the Singer addon): slots 0 = from the instrument owned; dummy = up to 2 dummy songs;
    -- marcato_song / clarion_song ('' = first / next song); aoe_names = members that must be within 10'
    songs = { list = '', duration = 240, refresh_before = 30, when = 'always', nitro = true, marcato = true, pianissimo = '',
              slots = 0, dummy = '', marcato_song = '', clarion_song = '', aoe_names = '' },
    -- entrust = 'Indi-Spell>Member'. full_circle_range = recall luopan when target is this far from it.
    -- entrust = 'auto' for Indi-Haste/Fury on the leader; hate_first = Dia before a Geo debuff;
    -- party_mp = Radial Arcana when 2+ members are under this MP%
    geo = { indi = '', geo = '', geo_target = 'bt', entrust = '', full_circle_range = 15, hate_first = true, party_mp = 40 },
    debuff = { list = 'Dia II', retries = 1 },
    triggers = { t1 = '' },
    bridge = { enabled = true, host = '127.0.0.1', port = 47000, interval = 1 },
    -- Playing alts (vg_alts): alerts on the leader's screen, mount sync, food & Reraise upkeep.
    -- Kept outside "modules" so presets don't switch them off.
    alts = { alerts = true, mount = true, upkeep = true, hud = true, stealth = true, restsync = true },
    hud = { x = 20, y = 320 },            -- alt overview box on the leader's screen
    keys = false,                         -- //vg keys on: Ctrl+F1..F6 hotkeys for alt orders
    setups = {},                          -- //vg setup save|load <name>: named team setups
    share = { emergency = 35 },           -- other healers still cure a member below this HP%
    -- GearSwap commands for //vg defense (Mote-style files) and auto-defense under 40% HP
    gear = { physical = 'gs c set DefenseMode Physical', magical = 'gs c set DefenseMode Magical',
             off = 'gs c reset DefenseMode', auto = false },
    away = { minutes = 20 },              -- alts pause when the leader hasn't moved for this long (0 = off)
    alerts = { hp = 30, mp = 10, far = 30, idle = 15, sound = '', ['repeat'] = 60 },
    mount = { name = 'Raptor' },
    upkeep = { food = '', reraise = '' },
    -- WHM / RDM / SCH know-how from the job guides (vg_mages): AoE -na, bar spells, Saboteur / Stymie,
    -- sleeping extra mobs (off until //vg sleep on), Scholar stratagems and Immanence skillchains.
    -- Corsair: risk = highest bust chance % to Double-Up into (0 = never bust), range = roll reach in yalms
    -- //vg update: GitHub page (owner/name) and folder that hold the newest Vanguard
    updater = { repo = 'Daviant123/Vanguard', path = 'Vanguard', branch = 'main', check = true },   -- //vg update (see take_old_update_section)
    cor = { risk = 0, snake_eye = true, fold = true, range = 8 },
    -- Scholar stratagems, main or sub SCH (vg_strat): which spells get which stratagem, reserve, Arts upkeep
    strat = { enabled = true, arts = 'auto', reserve = 1, jp_gift = false,
              perpetuance = 'Regen V,Regen IV,Regen III,Adloquium,Embrava,Haste,Haste II,Refresh,Refresh II,Refresh III,Phalanx,Phalanx II,Flurry,Flurry II,Aquaveil',
              accession = 'Regen V,Regen IV,Regen III,Regen II,Regen,Protect V,Protect IV,Shell V,Shell IV,Stoneskin,Blink,Aquaveil,Phalanx,Adloquium,Embrava',
              accession_count = 3, accession_cure = 3,
              penury = '', penury_mp = 30, celerity = 'Raise,Raise II,Raise III,Arise', celerity_hp = 30,
              rapture = '', rapture_hp = 0, altruism = '', tranquility = '',
              parsimony = '', parsimony_mp = 30, alacrity = '', manifestation = '', ebullience = '',
              focalization = '', equanimity = '' },
    mages = { aoe_na = true, bar = '', bar_status = '', pld = false, saboteur = true, stymie = true,
              sleep = false, sleep_skip = '', accession = true, perpetuance = true, immanence = true,
              chain = 'liquefaction', chain_every = 40 },
}

-- The update settings are called "updater", not "update": Windower's config library calls its own table method
-- :update on a copy of the settings when it first writes settings.xml (libs/config.lua, config.save), and a setting
-- named "update" hid that method - a brand-new install crashed at once with "libs/config.lua:344: attempt to call
-- method 'update' (a table value)" (a friend's first try, 2026-10-18). Older settings files still carry an <update>
-- section: it's taken out of the file before loading (so it can never hide the method again) and its on / off and
-- page are kept.
local function take_old_update_section()
    local path = (windower.addon_path or '') .. 'data/settings.xml'
    local f = io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    if not text:find('<update>', 1, true) then return nil end
    local old = {}
    for block in text:gmatch('<update>(.-)</update>') do
        local repo, check = block:match('<repo>([^<]*)</repo>'), block:match('<check>([^<]*)</check>')
        if repo and repo ~= '' then old.repo = repo end
        if check == 'false' then old.check = false end
    end
    text = text:gsub('%s*<update>.-</update>', '')
    local w = io.open(path, 'w')
    if w then w:write(text) w:close() end
    return old
end
local old_update = take_old_update_section()
local settings = config.load(defaults)
if old_update then
    if old_update.repo then settings.updater.repo = old_update.repo end
    if old_update.check == false then settings.updater.check = false end
end
-- Running or not is decided now, not by whatever was saved last time: only Auto start starts it by itself.
-- Windower's config library re-reads settings.xml right after loading and again at login (bringing back a saved
-- <enabled>true</enabled> - why CharB kept showing "running" with Auto start off), so it's applied again then.
-- ...except right after a reload (an update, //lua r): a character that was running carries on (resume_until is set
-- when it unloads). His report: "when I start farming it only stays on for about 2 minutes" - every update reload
-- switched farming off.
local resuming = (tonumber(settings.resume_until) or 0) > os.time()
settings.enabled = settings.autostart == true or resuming
if type(config.register) == 'function' then
    config.register(settings, function() settings.enabled = settings.autostart == true or resuming end)
end

------------------------------------------------------------------------
-- Runtime state
------------------------------------------------------------------------
local state = {
    last_tick = 0,
    busy_until = 0,
    running = false,
    party_buffs = {},     -- [player id] = {buff ids}
    attempts = {},        -- [key] = os.clock() of last attempt (anti-spam)
    raised = {},          -- [name] = os.clock()
    burst = nil,          -- {elements = {...}, expires = t, target = id}
    sc = { target = 0, step = 0, time = 0 },
    songs = {},           -- [song name] = os.clock() last sung
    debuffs = {},         -- [mob id] = {[spell name] = {tries=n, landed=bool}}
    dispel_until = 0,
    resting = false,
    entrust = nil,        -- {spell, target, expires}
    farm_pulled = {},     -- [mob id] = true
    route = nil,          -- parsed waypoints
    wp = 1, wp_dir = 1,
    recording = false,
    action_once = {},     -- [action id] = mob id
    profile = nil,        -- {job, role, ws, toggles}
    profile_sent = 0,
}

local function now() return os.clock() end

local function log(msg)
    windower.add_to_chat(207, '[Vanguard] ' .. msg)
    bridge.log(msg)
end

------------------------------------------------------------------------
-- Action helpers
------------------------------------------------------------------------
local function busy() return now() < state.busy_until end

local function stop_running()
    if state.running then
        windower.ffxi.run(false)
        state.running = false
    end
end

local function recently(key, secs)
    local t = state.attempts[key]
    return t and (now() - t) < secs
end

local function mark(key) state.attempts[key] = now() end

-- MP reserve (series 3 round 3): the healing kinds of spells that may still be cast below mana.reserve.
local KEEP_FOR = { Raise = true, ['Raise II'] = true, ['Raise III'] = true, Arise = true, Erase = true, Esuna = true,
                   Sacrifice = true }
local function healing_spell(spell)
    if KEEP_FOR[spell.en] then return true end
    if spell.en:find('^Cur') or spell.en:find('na$') then return true end        -- Cure / Curaga / Cura, the -na spells
    return false
end

local function cast(spell, target, why)
    local reserve = tonumber(settings.mana.reserve) or 0
    if reserve > 0 and (spell.mp_cost or 0) > 0 and not healing_spell(spell) then
        local p = windower.ffxi.get_player()
        if p and (p.vitals.mpp or 100) < reserve then
            if not recently('mp_reserve', 60) then
                mark('mp_reserve')
                log(('MP %d%% is under the %d%% kept for cures: %s waits'):format(p.vitals.mpp, reserve, spell.en))
            end
            return false
        end
    end
    if strat.before_cast(spell, target, why) then return true end      -- a stratagem first; the spell follows
    stop_running()
    windower.send_command(('input /ma "%s" %s'):format(spell.en, target))
    state.busy_until = now() + (spell.cast_time or 2) + 3
    state.no_move_until = now() + (spell.cast_time or 2) + 1     -- casting: can't walk, not "stuck"
    mark('ma:' .. spell.en .. ':' .. target)
    if why then log(('%s -> %s (%s)'):format(spell.en, target, why)) end
    return true
end

local function use_ja(ja, target)
    windower.send_command(('input /ja "%s" %s'):format(ja.en, target))
    state.busy_until = now() + 1.5
    mark('ja:' .. ja.en .. ':' .. target)
    return true
end

local function use_ws(ws_name)
    windower.send_command(('input /ws "%s" <t>'):format(ws_name))
    state.busy_until = now() + 2
    state.no_move_until = now() + 4          -- the weapon skill's animation: not "stuck" (vg_safety)
    mark('ws:' .. ws_name)
    log('WS: ' .. ws_name)
    return true
end

local function try_cast(name, target, why, player)
    local spell = util.spell(name)
    if not spell or not util.spell_ready(spell, player) then return false end
    if recently('ma:' .. spell.en .. ':' .. target, 4) then return false end
    return cast(spell, target, why)
end

local function can_act(player)
    if player.status ~= 0 and player.status ~= 1 then return false end   -- dead, resting, event
    return not busy()
end

local function silenced(player)
    return util.has_buff(player.buffs, 6) or util.has_buff(player.buffs, 29)  -- silence, mute
end

local function amnesia(player)
    return util.has_buff(player.buffs, 16)
end

------------------------------------------------------------------------
-- Party helpers
------------------------------------------------------------------------
local function party_members(range)
    local out = {}
    local party = windower.ffxi.get_party()
    if not party then return out end
    for _, key in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
        local m = party[key]
        if m and m.name and m.mob and m.mob.valid_target ~= false then
            if not range or util.dist(m.mob) <= range then
                out[#out + 1] = m
            end
        end
    end
    return out
end

local function buffs_of(member, player)
    if member.name == player.name then return player.buffs end
    return member.mob and state.party_buffs[member.mob.id]
end

local function leader_mob(player)
    if settings.leader == '' or settings.leader:lower() == player.name:lower() then return nil end
    return windower.ffxi.get_mob_by_name(settings.leader)
end

local function battle_target()
    local bt = windower.ffxi.get_mob_by_target('bt')
    if bt and bt.hpp > 0 and bt.valid_target then return bt end
    return nil
end

------------------------------------------------------------------------
-- Movement: follow and combat positioning
------------------------------------------------------------------------
local function run_toward(me, mob)
    local dx, dy = mob.x - me.x, mob.y - me.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.01 then return end
    windower.ffxi.run(dx / len, dy / len)
    state.running = true
    state.run_dir = { dx / len, dy / len }
end

local function face(me, mob)
    windower.ffxi.turn(-(math.atan2 or math.atan)(mob.y - me.y, mob.x - me.x))
end

local function do_movement(player)
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return end
    -- bringing a mob back to camp comes first (abilities wait until it's there)
    state.farm_bringing = nil
    if player.status == 1 and settings.modules.farm and settings.farm.pull_back and not state.hold then
        local t = windower.ffxi.get_mob_by_target('t')
        if t and t.hpp > 0 and party.pull_to_camp(player, me, t) then state.farm_bringing = t.id return end
    end
    if busy() then stop_running() return end
    if state.hold then stop_running() return end
    if safety.unstick() then return end

    -- Engaged melee: close to melee range on our target.
    local approach = (settings.modules.assist and settings.assist.approach)
        or (settings.modules.farm and settings.farm.approach)
    if player.status == 1 and approach then
        local t = windower.ffxi.get_mob_by_target('t')
        if t and t.hpp > 0 then
            if party.pull_to_camp(player, me, t) then return end   -- puller: back to camp, let it come
            local d = util.dist(t)
            -- farming: close in on its own mob from any distance (assist keeps the engage_range limit)
            if d > settings.assist.melee_range and (d < settings.assist.engage_range or (settings.modules.farm and settings.farm.approach)) then
                run_toward(me, t)
            else
                stop_running()
                face(me, t)
            end
            return
        end
    end

    -- Camp spot / formation behind the leader (vg_party), else plain follow - not for the farmer: it leads.
    if not settings.modules.farm and party.movement(player, me) then return end
    if settings.modules.follow and not settings.modules.farm then
        local l = leader_mob(player)
        if l then
            local d = util.dist(l)
            if d > settings.follow.distance and d < settings.follow.max_distance then
                run_toward(me, l)
                return
            end
        end
    end
    if settings.modules.farm and player.status == 0 and state.route_moving then return end
    stop_running()
end

------------------------------------------------------------------------
-- Assist / engage
------------------------------------------------------------------------
local function do_assist(player)
    if not settings.modules.assist or not settings.assist.engage or state.hold or state.retreat then return false end
    if settings.modules.farm then return false end              -- the farmer picks its own mobs
    local l = leader_mob(player)
    if not l or l.status ~= 1 or not l.target_index or l.target_index == 0 then return false end
    local lt = windower.ffxi.get_mob_by_index(l.target_index)
    if not lt or lt.hpp == 0 or not lt.valid_target then return false end
    if util.dist(lt) > settings.assist.engage_range then return false end
    -- the leader is bringing it back to camp: wait there for it
    if player.status == 0 and party.mob_far_from_camp(lt) then return false end

    if player.status == 0 then
        if recently('engage', 4) then return false end
        mark('engage')
        windower.send_command(('input /assist %s; wait 1.2; input /attack <t>'):format(settings.leader))
        state.busy_until = now() + 2
        log('Engaging ' .. lt.name)
        return true
    elseif player.status == 1 then
        local t = windower.ffxi.get_mob_by_target('t')
        if (not t or t.id ~= lt.id) and not recently('switch', 4) then
            mark('switch')
            windower.send_command(('input /assist %s'):format(settings.leader))
            state.busy_until = now() + 1.5
            log('Switching to ' .. lt.name)
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- Healing, raising, status removal
------------------------------------------------------------------------
local cure_tiers = {
    {'Cure VI', 1300}, {'Cure V', 1000}, {'Cure IV', 650},
    {'Cure III', 350}, {'Cure II', 170}, {'Cure', 70},
}
local curaga_tiers = {'Curaga V', 'Curaga IV', 'Curaga III', 'Curaga II', 'Curaga'}
local raise_tiers = {'Arise', 'Raise III', 'Raise II', 'Raise'}

local status_cures = {
    {'petrification', 'Stona'}, {'doom', 'Cursna'}, {'paralysis', 'Paralyna'},
    {'silence', 'Silena'}, {'curse', 'Cursna'}, {'plague', 'Viruna'},
    {'disease', 'Viruna'}, {'blindness', 'Blindna'}, {'poison', 'Poisona'},
    {'slow', 'Erase'}, {'weight', 'Erase'}, {'bind', 'Erase'}, {'Addle', 'Erase'},
    {'Elegy', 'Erase'}, {'Requiem', 'Erase'}, {'Threnody', 'Erase'}, {'Helix', 'Erase'},
    {'Bio', 'Erase'}, {'Dia', 'Erase'}, {'Flash', 'Erase'}, {'Burn', 'Erase'}, {'Frost', 'Erase'},
    {'Choke', 'Erase'}, {'Rasp', 'Erase'}, {'Shock', 'Erase'}, {'Drown', 'Erase'},
    {'Attack Down', 'Erase'}, {'Defense Down', 'Erase'}, {'Accuracy Down', 'Erase'},
    {'Evasion Down', 'Erase'}, {'Magic Atk. Down', 'Erase'}, {'Magic Acc. Down', 'Erase'},
    {'Magic Def. Down', 'Erase'}, {'Max HP Down', 'Erase'}, {'Max MP Down', 'Erase'},
    {'STR Down', 'Erase'}, {'DEX Down', 'Erase'}, {'VIT Down', 'Erase'}, {'AGI Down', 'Erase'},
    {'INT Down', 'Erase'}, {'MND Down', 'Erase'}, {'CHR Down', 'Erase'},
    {'Amnesia', 'Esuna'},
}
local status_ids = {}
for _, pair in ipairs(status_cures) do
    local id = util.buff_id(pair[1])
    if id then status_ids[#status_ids + 1] = {id, pair[2], pair[1]} end
end

-- The cure tiers from settings.heal.tiers ("Cure IV:650,..."), biggest first; 0 leaves a tier out.
local function tiers()
    local out = {}
    for _, entry in ipairs(util.split(settings.heal.tiers or '', ',')) do
        local name, hp = entry:match('^(.-)%s*:%s*(%d+)$')
        if name and tonumber(hp) > 0 then out[#out + 1] = { name, tonumber(hp) } end
    end
    if #out == 0 then return cure_tiers end
    table.sort(out, function(a, b) return a[2] > b[2] end)
    return out
end

local function pick_cure(missing, player)
    local best
    local list = tiers()
    for i = #list, 1, -1 do                 -- smallest first
        local s = util.spell(list[i][1])
        if util.spell_ready(s, player) then
            best = s
            if list[i][2] >= missing then return s end
        end
    end
    return best                              -- biggest available
end

local sleep_ids = {2, 19}   -- sleep, lullaby/sleep II

local function do_heal(player)
    if not settings.modules.heal or silenced(player) then return false end
    local members = {}
    local ignore = {}
    for _, n in ipairs(util.split(settings.heal.ignore, ',')) do ignore[n:lower()] = true end
    for _, m in ipairs(party_members(settings.heal.range)) do
        if not ignore[m.name:lower()] then members[#members + 1] = m end
    end

    -- Wake sleeping members (CurePlease "wake sleep").
    if settings.heal.wake_sleep then
        for _, m in ipairs(members) do
            local bl = buffs_of(m, player)
            if m.name ~= player.name and m.hpp > 0 and bl
                and (util.has_buff(bl, sleep_ids[1]) or util.has_buff(bl, sleep_ids[2])) then
                for _, name in ipairs({'Cure', 'Cure II', 'Curaga'}) do
                    if try_cast(name, m.name, 'wake ' .. m.name, player) then return true end
                end
            end
        end
    end

    local priority = {}
    for _, n in ipairs(util.split(settings.heal.priority, ',')) do priority[n:lower()] = true end

    local worst, worst_hpp, low_count = nil, 101, 0
    for _, m in ipairs(members) do
        if m.hpp > 0 then
            if m.hpp < settings.heal.curaga_at then low_count = low_count + 1 end
            local is_prio = priority[m.name:lower()]
            local threshold = is_prio and settings.heal.priority_at or settings.heal.cure_at
            -- Priority members sort ahead of everyone else.
            local score = is_prio and (m.hpp - 100) or m.hpp
            if m.hpp < threshold and score < worst_hpp and not share.being_cured(m) then
                worst, worst_hpp = m, score
            end
        end
    end
    if not worst then return false end

    if settings.heal.curaga and low_count >= settings.heal.curaga_count then
        local allowed = {}
        for _, n in ipairs(util.split(settings.heal.curagas or '', ',')) do allowed[n:lower()] = true end
        for _, name in ipairs(curaga_tiers) do
            if allowed[name:lower()] and try_cast(name, worst.name, low_count .. ' members hurt', player) then
                local sp = util.spell(name)
                share.cure(player, '*', sp and sp.cast_time or 3)
                return true
            end
        end
    end
    local max_hp = worst.hpp > 0 and math.floor(worst.hp * 100 / worst.hpp) or worst.hp
    local spell = pick_cure(max_hp - worst.hp, player)
    if spell and not recently('ma:' .. spell.en .. ':' .. worst.name, 3) then
        share.cure(player, worst.name, spell.cast_time or 3)
        return cast(spell, worst.name, worst.name .. ' at ' .. worst.hpp .. '%')
    end
    return false
end

local function do_raise(player)
    if not settings.modules.raise or silenced(player) then return false end
    for _, m in ipairs(party_members(20)) do
        if m.hpp == 0 and m.name ~= player.name then
            local t = state.raised[m.name]
            if not t or now() - t > 60 then
                for _, name in ipairs(raise_tiers) do
                    if try_cast(name, m.name, 'KO', player) then
                        state.raised[m.name] = now()
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function do_status(player)
    if not settings.modules.cleanse or silenced(player) then return false end
    local ignore, skip = {}, {}
    for _, n in ipairs(util.split(settings.heal.ignore, ',')) do ignore[n:lower()] = true end
    for _, n in ipairs(util.split(settings.cleanse.skip, ',')) do skip[n:lower()] = true end
    local members, wanted = {}, {}
    for _, m in ipairs(party_members(settings.heal.range)) do
        if not ignore[m.name:lower()] then members[#members + 1] = m end
    end
    for _, entry in ipairs(status_ids) do
        if not skip[entry[3]:lower()] then wanted[#wanted + 1] = entry end
    end
    if mages.aoe_na(player, wanted, members) then return true end
    for _, m in ipairs(members) do
        local bl = buffs_of(m, player)
        if bl and m.hpp > 0 then
            for _, entry in ipairs(status_ids) do
                if not skip[entry[3]:lower()] and util.has_buff(bl, entry[1]) then
                    if try_cast(entry[2], m.name, entry[3], player) then return true end
                end
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Buff upkeep
------------------------------------------------------------------------
local function do_buffs(player)
    if not settings.modules.buffs then return false end
    local members = {}
    for _, m in ipairs(party_members(20)) do members[m.name:lower()] = m end

    for _, entry in ipairs(util.split(settings.buffs.list, ',')) do
        local what, who = entry:match('^(.-)%s*>%s*(.+)$')
        what, who = what or entry, who or 'me'
        local is_ja = what:lower():sub(1, 3) == 'ja:'
        if is_ja then what = util.trim(what:sub(4)) end

        local target_name = (who:lower() == 'me') and player.name or who
        local m = members[target_name:lower()]
        if m then
            local bl = buffs_of(m, player)
            local action = is_ja and util.ability(what) or util.spell(what)
            if action and bl then
                local buff_id = action.status or util.buff_id(what:gsub('%s+[IVX]+$', ''))
                if buff_id and not util.has_buff(bl, buff_id) then
                    local tgt = (target_name == player.name) and '<me>' or target_name
                    if is_ja then
                        if not amnesia(player) and util.ability_ready(action)
                            and not recently('ja:' .. action.en .. ':' .. tgt, 5) then
                            return use_ja(action, tgt)
                        end
                    elseif not silenced(player) and util.spell_ready(action, player)
                        and not recently('ma:' .. action.en .. ':' .. tgt, 6) then
                        return cast(action, tgt, 'buff')
                    end
                end
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Weapon skills, skillchains, magic bursts
------------------------------------------------------------------------
local function sc_steps()
    local steps = {}
    for _, s in ipairs(util.split(settings.sc.steps, ',')) do
        local who, ws = s:match('^(.-)%s*:%s*(.+)$')
        if who and ws then steps[#steps + 1] = {who = who:lower(), ws = ws} end
    end
    return steps
end

local function party_tp(name)
    for _, m in ipairs(party_members()) do
        if m.name:lower() == name then return m.tp or 0 end
    end
    return 0
end

local function ws_in_range(t)
    return t and t.hpp >= settings.ws.min_mob_hpp and util.dist(t) <= settings.ws.max_range
end

local function do_skillchain(player)
    if not settings.modules.sc or player.status ~= 1 or amnesia(player) then return false end
    local steps = sc_steps()
    if #steps == 0 then return false end
    local t = windower.ffxi.get_mob_by_target('t')
    if not ws_in_range(t) then return false end
    local me = player.name:lower()

    -- Expire an unfinished chain.
    if state.sc.step > 0 and (now() - state.sc.time > settings.sc.window_max or state.sc.target ~= t.id) then
        state.sc = { target = 0, step = 0, time = 0 }
    end

    local next_step = state.sc.step + 1
    local step = steps[next_step]
    if not step or step.who ~= me or player.vitals.tp < 1000 then return false end

    if next_step == 1 then
        -- Open only when every participant has enough TP to continue.
        if player.vitals.tp < settings.sc.open_tp then return false end
        for i = 2, #steps do
            if steps[i].who ~= me and party_tp(steps[i].who) < 1000 then return false end
        end
        return use_ws(step.ws)
    end
    local elapsed = now() - state.sc.time
    if elapsed >= settings.sc.window_min and elapsed <= settings.sc.window_max then
        return use_ws(step.ws)
    end
    return false
end

local function do_ws(player)
    if not settings.modules.ws or player.status ~= 1 or amnesia(player) then return false end
    local t = windower.ffxi.get_mob_by_target('t')
    local fin = finish.ws(player, t)                                  -- the finishing weapon skill comes first
    if fin == 'used' then return true elseif fin == 'block' then return false end
    if settings.ws.name == '' then return false end
    if settings.modules.sc then
        for _, s in ipairs(sc_steps()) do
            if s.who == player.name:lower() then return false end   -- chain owns our TP
        end
    end
    if player.vitals.tp < settings.ws.tp or recently('ws:' .. settings.ws.name, 3) then return false end
    if not ws_in_range(t) then return false end
    return use_ws(settings.ws.name)
end

local function burst_map()
    local map = {}
    for _, entry in ipairs(util.split(settings.burst.spells, ',')) do
        local el, list = entry:match('^(.-)%s*:%s*(.+)$')
        if el then map[el:lower()] = util.split(list, '|') end
    end
    return map
end

local function do_burst(player)
    if not settings.modules.burst or not state.burst or silenced(player) then return false end
    if now() > state.burst.expires then state.burst = nil return false end
    local map = burst_map()
    for _, element in ipairs(state.burst.elements) do
        for _, name in ipairs(map[element:lower()] or {}) do
            if try_cast(name, '<bt>', 'burst ' .. state.burst.chain, player) then
                state.burst = nil
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Songs, Geomancy, enfeebles, dispel
------------------------------------------------------------------------
-- "In a fight": I'm engaged, the leader is, anyone in the party is, or the party has a claimed mob (<bt>). It used to
-- be only me or the leader - a bard set to "Nobody (I lead)" standing back never saw a fight, so NiTro, Clarion Call
-- and the other "in a fight" abilities never went off (2026-10-18)
local function party_engaged(player)
    if player.status == 1 then return true end
    local l = leader_mob(player)
    if l and l.status == 1 then return true end
    local pt = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        local m = pt[k] and pt[k].mob
        if m and m.status == 1 and (m.distance or 0) < 900 then return true end
    end
    return battle_target() ~= nil
end

local function do_songs(player)
    if not settings.modules.songs or settings.songs.list == '' or silenced(player) then return false end
    if settings.songs.when == 'engaged' and not party_engaged(player) then return false end
    return bard.sing(player)
end

local function do_geo(player)
    if not settings.modules.geo or silenced(player) then return false end
    -- Full Circle when the luopan isn't reaching anyone (vg_support.luopan_off); the bubble is put down again below
    local pet = windower.ffxi.get_mob_by_target('pet')
    local why = pet and support.luopan_off(player, pet, battle_target())
    if why then
        local fc = util.ability('Full Circle')
        if util.ability_ready(fc) and not amnesia(player) and not recently('ja:Full Circle:<me>', 15) then
            log('Full Circle (' .. why .. ')')
            return use_ja(fc, '<me>')
        end
    end
    -- Entrust: "Indi-Spell>Member"
    local entrust = support.entrust_setting(player)
    if entrust ~= '' and party_engaged(player) then
        local spell, who = entrust:match('^(.-)%s*>%s*(.+)$')
        if spell and who then
            if util.has_buff(player.buffs, util.buff_id('Entrust')) then
                if try_cast(spell, who, 'entrust', player) then return true end
            else
                local ent = util.ability('Entrust')
                local target_has = false
                for _, m in ipairs(party_members(20)) do
                    if m.name:lower() == who:lower() then
                        target_has = util.has_buff(buffs_of(m, player) or {}, 612)
                    end
                end
                if not target_has and util.ability_ready(ent) and util.spell_ready(util.spell(spell), player)
                    and not recently('ja:Entrust:<me>', 30) then
                    return use_ja(ent, '<me>')
                end
            end
        end
    end
    -- Indi: keep "Colure Active" on self.
    if settings.geo.indi ~= '' and not util.has_buff(player.buffs, 612) then
        if try_cast(settings.geo.indi, '<me>', 'indi', player) then return true end
    end
    -- Geo: keep a luopan out.
    if settings.geo.geo ~= '' and not windower.ffxi.get_mob_by_target('pet') then
        local tgt = settings.geo.geo_target
        if tgt == 'bt' then
            if party_engaged(player) and battle_target() then
                if support.geo_hate(player, util.spell(settings.geo.geo), battle_target()) then return true end
                return try_cast(settings.geo.geo, '<bt>', 'geo', player)
            end
        else
            return try_cast(settings.geo.geo, tgt == 'me' and '<me>' or tgt, 'geo', player)
        end
    end
    return false
end

local function do_debuff(player)
    if not settings.modules.debuff or silenced(player) then return false end
    local bt = battle_target()
    if not bt or util.dist(bt) > 21 then return false end
    state.debuffs[bt.id] = state.debuffs[bt.id] or {}
    local rec = state.debuffs[bt.id]
    for _, name in ipairs(util.split(settings.debuff.list, ',')) do
        local r = rec[name] or {tries = 0, landed = false}
        rec[name] = r
        if not share.debuff_blocked(r) and r.tries <= settings.debuff.retries then
            if mages.before_enfeeble(player, bt, name, r) then return true end
            if try_cast(name, '<bt>', 'debuff', player) then
                r.tries = r.tries + 1
                share.debuff(bt.id, name, 'cast')
                return true
            end
        end
    end
    return false
end

local function do_dispel(player)
    if not settings.modules.dispel or now() > state.dispel_until or silenced(player) then return false end
    if try_cast('Dispelga', '<bt>', 'mob buffed', player) or try_cast('Dispel', '<bt>', 'mob buffed', player) then
        state.dispel_until = 0
        return true
    end
    return false
end


------------------------------------------------------------------------
-- Rest, MP management, trusts (CurePlease / EasyFarm style)
------------------------------------------------------------------------
-- Something attacking the party right now (a mob our party has claimed, alive, close by)? Then nobody sits down to rest.
-- (Found by the farming simulator: a mob hitting a low-HP farmer interrupted its rest, and it sat down again, and again.)
-- A mob is fighting us: claimed by the party, or going for one of us (a mob on us after /attackoff - waiting for TP to
-- finish it - still counts: his report 2026-10-17, "if in combat the bot should not try to summon trusts, or if under
-- attack")
local function under_attack(player)
    local ids, idx = {}, {}
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        if p[k] and p[k].mob then ids[p[k].mob.id] = true if p[k].mob.index then idx[p[k].mob.index] = true end end
    end
    for _, m in pairs(windower.ffxi.get_mob_array() or {}) do
        if type(m) == 'table' and m.spawn_type == 16 and (m.hpp or 0) > 0 and util.dist(m) <= 20
            and ((m.claim_id and ids[m.claim_id]) or (m.status == 1 and m.target_index and idx[m.target_index])) then
            return true
        end
    end
    return false
end

local function do_rest(player)
    if not settings.modules.rest then return false end
    local v, r = player.vitals, settings.rest
    if player.status == 33 then
        -- Stand up when recovered (MP check only for jobs with MP).
        local mp_ok = (v.max_mp or 0) == 0 or v.mpp >= r.mp_high
        if v.hpp >= r.hp_high and mp_ok then
            windower.send_command('input /heal off')
            state.resting = false
            log('Done resting')
            return true
        end
        return false
    end
    if player.status ~= 0 or party_engaged(player) or state.running or under_attack(player) then return false end
    local low_mp = (v.max_mp or 0) > 0 and v.mpp < r.mp_low
    if (v.hpp < r.hp_low or low_mp) and not recently('rest', 6) then
        mark('rest')
        windower.send_command('input /heal on')
        state.resting = true
        log(('Resting (HP %d%%, MP %d%%)'):format(v.hpp, v.mpp))
        return true
    end
    return false
end

local function do_mana(player)
    if not settings.modules.mana or amnesia(player) then return false end
    local v = player.vitals
    -- Sublimation: start charging, then release when MP is low.
    if settings.mana.sublimation then
        local sub = util.ability('Sublimation')
        if sub and util.ability_ready(sub) and not recently('ja:Sublimation:<me>', 10) then
            local active = util.has_buff(player.buffs, util.buff_id('Sublimation: Activated'))
            local complete = util.has_buff(player.buffs, util.buff_id('Sublimation: Complete'))
            if (not active and not complete) or (complete and v.mpp < settings.mana.sublimation_mpp) then
                return use_ja(sub, '<me>')
            end
        end
    end
    -- Convert when MP is very low and HP is healthy.
    if settings.mana.convert_mpp > 0 and v.mpp < settings.mana.convert_mpp and v.hpp > 80 then
        local conv = util.ability('Convert')
        if conv and util.ability_ready(conv) and not recently('ja:Convert:<me>', 10) then
            log('Convert')
            return use_ja(conv, '<me>')
        end
    end
    return false
end

local function do_trusts(player)
    if not settings.modules.trusts or settings.trusts.list == '' or player.status ~= 0 then return false end
    if party_engaged(player) or silenced(player) or under_attack(player) or state.finish_wait then return false end
    local members = party_members()
    if #members >= settings.trusts.party_size then return false end
    local present = {}
    for _, m in ipairs(members) do present[m.name:lower()] = true end
    for _, name in ipairs(util.split(settings.trusts.list, ',')) do
        local short = name:lower():gsub('%s*%(.-%)', ''):gsub('%s+ii$', '')
        if not present[short] and not present[name:lower()] then
            if try_cast(name, '<me>', 'trust', player) then return true end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Farming lives in vg_farm.lua (camp / route, give-up list, wait for the party, stop conditions, stats, spots)
------------------------------------------------------------------------
local function record_route()
    if not state.recording then return end
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return end
    local pts = state.recording_pts
    local last = pts[#pts]
    if not last or math.sqrt((me.x - last.x) ^ 2 + (me.y - last.y) ^ 2) >= 4 then
        pts[#pts + 1] = {x = me.x, y = me.y, z = me.z}
    end
end


------------------------------------------------------------------------
-- Job profiles: automatic per-job setup
------------------------------------------------------------------------
local function make_ctx(player)
    return {
        player = player, settings = settings, state = state,
        cast = cast, use_ja = use_ja, log = log, recently = recently, mark = mark,
        silenced = silenced, amnesia = amnesia, party_members = party_members,
        buffs_of = buffs_of, party_engaged = party_engaged, battle_target = battle_target,
        pld_in_party = function(p) return mages.pld_in_party(p) end,
        roll_in_range = support.roll_in_range, roll_approach = support.roll_approach,
    }
end

local function encode_profile(pr)
    local on, off = {}, {}
    for id, v in pairs(pr.toggles) do
        if v then on[#on + 1] = id else off[#off + 1] = id end
    end
    -- '+' separates ids (commas would be split by Windower's config library).
    return ('role=%s|ws=%s|on=%s|off=%s|o=%s|q=%s'):format(pr.role, pr.ws or '', table.concat(on, '+'), table.concat(off, '+'),
        link.encode_opts(pr.opts), table.concat(pr.order or {}, '+'))
end

local function decode_profile(job, str)
    local pr = { job = job, toggles = {} }
    for k, v in str:gmatch('(%w+)=([^|]*)') do
        if k == 'role' then pr.role = v
        elseif k == 'ws' then pr.ws = v
        elseif k == 'on' then for _, id in ipairs(util.split(v, '+')) do pr.toggles[id] = true end
        elseif k == 'off' then for _, id in ipairs(util.split(v, '+')) do pr.toggles[id] = false end
        elseif k == 'o' then pr.opts = link.decode_opts(v)
        elseif k == 'q' then pr.order = util.split(v, '+')    -- ability priority order
        end
    end
    return pr
end

local function known_ws()
    local list = {}
    local ab = windower.ffxi.get_abilities()
    for _, id in pairs(ab and ab.weapon_skills or {}) do
        local ws = res.weapon_skills[id]
        if ws then list[#list + 1] = ws.en end
    end
    table.sort(list)
    return list
end

local function default_ws(job)
    local known = {}
    for _, n in ipairs(known_ws()) do known[n:lower()] = n end
    for _, n in ipairs((jobs[job] and jobs[job].ws) or {}) do
        if known[n:lower()] then return known[n:lower()] end
    end
    return ''
end

-- Turn the role into module settings.
local function apply_profile(pr)
    local job = pr.job
    local def = jobs[job] or {}
    local mods = jobs.role_modules[pr.role] or jobs.role_modules.melee
    for k in pairs(settings.modules) do settings.modules[k] = mods[k] == true end
    settings.assist.approach = not jobs.ranged_roles[pr.role]
    if def.songs then
        settings.modules.songs = true
        settings.songs.list = def.songs[pr.role] or def.songs.support or ''
    end
    if def.geo then
        local g = def.geo[pr.role] or def.geo.support
        settings.modules.geo = true
        settings.geo.indi, settings.geo.geo, settings.geo.geo_target = g.indi, g.geo, g.geo_target
    end
    if def.debuffs and def.debuffs[pr.role] then
        settings.debuff.list = def.debuffs[pr.role]
        settings.modules.debuff = true
    end
    settings.ws.name = pr.ws or ''
    settings.modules.ws = settings.modules.ws and settings.ws.name ~= ''
    state.profile = pr
end

local function save_profile()
    if not state.profile then return end
    util.job_set(settings.profiles, state.profile.job, encode_profile(state.profile))
    util.job_set(settings.menus, state.profile.job, menu.encode(settings))
    store.save(settings)
end

local function send_profile(player)
    player = player or windower.ffxi.get_player()
    local pr = state.profile
    if not player or not pr then return end
    local roles = {}
    for _, r in ipairs(jobs.roles_for(player.main_job)) do
        roles[#roles + 1] = { id = r, label = jobs.role_labels[r] or r }
    end
    bridge.send({
        type = 'profile', name = player.name,
        job = player.main_job, sub = player.sub_job or '',
        role = pr.role, roles = roles,
        ws = settings.ws.name, ws_list = known_ws(),
        actions = engine.list(pr, player),
        leader = settings.leader,
        menu = menu.catalog(player, status_cures),
        config = (function()
            local c = menu.config(settings)
            c.strat_info = strat.info(player)
            if player.main_job == 'BRD' then c.bard_info = bard.info(player) end
            c.known = quick.known(player)                -- for the app's quick buttons
            c.hotkeys = settings.hotkeys
            return c
        end)(),
        party = menu.party(),
    })
    state.profile_sent = now()
end

-- //vg rolls: switch the Corsair's roll actions to this set.
local function apply_rolls(set)
    if not state.profile then return end
    local on, names = {}, {}
    for _, id in ipairs(set) do on[id] = true end
    for _, a in ipairs(jobs.COR.actions) do
        if a.kind == 'roll' then
            state.profile.toggles[a.id] = on[a.id] == true
            if on[a.id] then names[#names + 1] = a.name end
        end
    end
    save_profile()
    send_profile()
    log('Rolls: ' .. table.concat(names, ' + '))
end

local function load_profile(player, force_default)
    player = player or windower.ffxi.get_player()
    if not player or not player.main_job then return end
    local job = player.main_job
    local saved = util.job_get(settings.profiles, job)
    local pr
    if saved and saved ~= '' and not force_default then
        pr = decode_profile(job, saved)
    end
    if not pr or not pr.role then
        pr = { job = job, role = jobs.roles_for(job)[1], ws = default_ws(job), toggles = {} }
    end
    if not pr.ws or pr.ws == '' then pr.ws = default_ws(job) end
    menu.reset_cache()
    apply_profile(pr)
    local saved_menu = util.job_get(settings.menus, job)
    if saved_menu and saved_menu ~= '' and not force_default then
        menu.apply(settings, saved_menu)
    else
        settings.buffs.list = ''
    end
    log(('%s %s ready (%s%s)'):format(job, player.sub_job and ('/' .. player.sub_job) or '',
        jobs.role_labels[pr.role] or pr.role, pr.ws ~= '' and (', WS ' .. pr.ws) or ''))
    send_profile(player)
end

local function pre_ws_filter(a) return a.tp_min ~= nil end
local function normal_filter(a) return a.tp_min == nil end

------------------------------------------------------------------------
-- Main tick
------------------------------------------------------------------------
party.init(settings, state, {
    log = log, recently = recently, mark = mark, run_toward = run_toward, stop_running = stop_running,
    party_engaged = party_engaged, leader_mob = leader_mob, face = face,
})
hud.init(settings, state, { log = log })
combat.init(settings, state, { log = log, recently = recently, mark = mark, leader_mob = leader_mob })
share.init(settings, state, { log = log })
safety.init(settings, state, { log = log, recently = recently, mark = mark, stop_running = stop_running })
team.init(settings, state, {
    log = log, store = store.save, save_profile = save_profile, order = party.order,
    load_profile = function(p) load_profile(p) end,
})
travel.init(settings, state, {
    log = log, recently = recently, mark = mark, try_cast = try_cast, party_engaged = party_engaged,
    ability = util.ability, ability_ready = util.ability_ready,
})
update.init(settings, log, function() store.save(settings) end)
local function ja_ready(name)
    local ja = util.ability(name)
    if not ja or not util.ability_ready(ja) then return nil end
    local ab = windower.ffxi.get_abilities()
    for _, id in pairs(ab and ab.job_abilities or {}) do if id == ja.id then return ja end end
    return nil
end
quick.init(settings, state, { log = log })
warp.init(settings, state, { log = log })
stats.kill_hook = function(mob) farm.on_kill(mob) trials.on_kill(mob) end
trials.init(settings, state, { log = log, save = function() store.save(settings) send_profile() end })
stats.chain_hook = function(n) farm.on_points(n) end
farm.init(settings, state, { log = log, run_toward = run_toward, stop_running = stop_running, face = face,
    party_engaged = party_engaged, recently = recently, mark = mark, save = function() save_profile() store.save(settings) send_profile() end,
    send = bridge.send })
finish.init(settings, state, { log = log, use_ws = use_ws, ws_in_range = ws_in_range, recently = recently, mark = mark,
    save = function() store.save(settings) end })
bard.init(settings, state, {
    log = log, recently = recently, mark = mark, try_cast = try_cast, use_ja = use_ja, amnesia = amnesia,
    party_members = party_members, ja_ready = ja_ready,
    nitro = function(p, due) return support.nitro(p, due) end,
    nitro_wait = function(p) return support.nitro_wait(p) end,
    -- Clarion Call for the songs: only if ticked in the abilities, its "when" holds and it's ready; true = used now
    clarion_ok = function(p)
        if not state.profile or util.has_buff(p.buffs, 499) or amnesia(p) then return false end
        for _, a in ipairs(jobs.actions_for(p.main_job)) do
            if a.id == 'clarion_call' and engine.enabled(a, state.profile) then
                local w = engine.effective(a, state.profile).when
                if w ~= 'always' and not party_engaged(p) then return false end
                local ja = ja_ready('Clarion Call', p)
                return ja and use_ja(ja, '<me>') or false
            end
        end
        return false
    end,
})
strat.init(settings, state, {
    log = log, recently = recently, use_ja = use_ja, cast = cast, party_members = party_members,
    buffs_of = buffs_of, amnesia = amnesia,
})
link.init(settings, state, {
    log = log, store = store.save, save_profile = save_profile, load_profile = function(p) load_profile(p) end,
})
bridge.on_cfg = function(json)
    local player = windower.ffxi.get_player()
    if player then link.on_cfg(player, json) end
end
support.init(settings, state, {
    log = log, recently = recently, mark = mark, cast = cast, use_ja = use_ja, try_cast = try_cast, silenced = silenced,
    amnesia = amnesia, party_members = party_members, buffs_of = buffs_of, battle_target = battle_target,
    party_engaged = party_engaged, leader_mob = leader_mob, run_toward = run_toward, stop_running = stop_running,
})
mages.init(settings, state, {
    log = log, recently = recently, mark = mark, cast = cast, use_ja = use_ja, silenced = silenced,
    amnesia = amnesia, party_members = party_members, buffs_of = buffs_of, battle_target = battle_target,
    party_engaged = party_engaged, leader_mob = leader_mob,
})
alts.init(settings, state, {
    log = log, bridge_log = function(m) bridge.log(m) end, recently = recently, mark = mark,
    try_cast = try_cast, party_engaged = party_engaged,
})

local function tick()
    local player = windower.ffxi.get_player()
    if not player then return end
    record_route()
    -- reloaded while running: carry on (farming too: a new run from the same camp), and forget the marker
    if resuming then
        resuming = false
        settings.resume_until = 0
        if settings.modules.farm and settings.enabled then
            farm.start(player, windower.ffxi.get_mob_by_target('me'))
            log('Reloaded: farming carries on')
        end
        store.save(settings)
    end
    -- a rest that ended without us (hit by a mob, moved): stop thinking we're resting
    if state.resting and player.status ~= 33 and not recently('rest', 3) and not recently('farm:rest', 3) then state.resting = false end
    stats.tick(player)
    if farm.rezone_due() then windower.send_command('vg farming start') end
    farm.loot_tick()
    farm.kill_watch()
    farm.fight_tick(player)
    farm.check_stop(player)
    warp.tick(player)
    alts.broadcast_mount(player)
    party.hello(player)
    party.send_pos(player)
    hud.send(player)
    hud.draw()
    travel.broadcast(player)
    if not settings.enabled then return end
    alts.alerts(player)
    if safety.away(player) then return end

    if player.status == 33 then
        if farm.rest_check(player) then return end                 -- resting at camp: up when a mob shows up
        if farm.rest_called_check(player) then return end          -- the farmer asked me to rest: up when full
        if not travel.rest_stand(player) then do_rest(player) end
        return
    end
    if player.status ~= 0 and player.status ~= 1 then stop_running() return end
    do_movement(player)
    support.roll_walk_tick(player)
    safety.watch(player)
    safety.auto_defense(player)
    if player.main_job == 'SCH' or player.sub_job == 'SCH' then
        state.strat_now = ('%d/%d'):format(strat.charges(player), strat.max_charges(player))
    end
    if not can_act(player) then return end
    if strat.run_queue() then return end                             -- the spell that waited for its stratagem
    if alts.mount_sync(player) then return end
    -- Retreat: stop fighting first (the movement step then brings us back).
    if state.retreat and player.status == 1 and not recently('attackoff', 3) then
        mark('attackoff')
        windower.send_command('input /attackoff')
        return
    end
    if travel.tick(player) then return end
    if combat.tick(player) then return end

    if settings.modules.triggers and triggers.run(settings, player, state) then
        state.busy_until = now() + 1.5
        return
    end

    if not state.profile then load_profile(player) end
    local ctx = make_ctx(player)
    local pr = state.profile

    if state.farm_bringing then return end                          -- running a mob back to camp: nothing else now
    if settings.modules.farm and player.status == 1 then   -- (abilities run first in a fight, so say it here)
        local t = windower.ffxi.get_mob_by_target('t')
        farm.status('fighting ' .. (t and t.name or 'a mob'))
    elseif settings.modules.farm then
        farm.status('getting ready first (cures, buffs, abilities)')   -- farm.tick says more once it gets its turn
    end
    -- A mob being finished with a set weapon skill (vg_finish): the others leave it alone, the finisher waits for TP.
    -- Only curing, buffing and songs then.
    if finish.held(player) or finish.waiting(player) then
        local _ = do_raise(player) or do_heal(player) or do_status(player) or do_geo(player) or do_songs(player)
            or do_buffs(player)
        return
    end
    -- a bard's songs come right after raise / cures / status removal (Singer's order): behind steps, Elegy and the rest
    -- the Troubadour minute ran out before the songs were done (2026-10-18)
    local function bard_first() return player.main_job == 'BRD' and (do_songs(player) or support.pianissimo(player)) end
    local _ = do_raise(player) or do_heal(player) or do_status(player) or bard_first() or strat.arts(player) or mages.crowd(player)
        or do_assist(player) or farm.pull(player) or support.double_up(ctx, engine) or mages.bar(player)
        or engine.run(ctx, pr, pre_ws_filter) or do_skillchain(player) or do_ws(player)
        or do_burst(player) or mages.sch(player) or engine.run(ctx, pr, normal_filter) or do_mana(player)
        or do_dispel(player) or do_debuff(player)
        or support.radial(player) or do_geo(player) or do_songs(player) or support.pianissimo(player) or do_buffs(player) or alts.upkeep(player)
        or do_rest(player) or do_trusts(player) or farm.tick(player)
end

windower.register_event('prerender', function()
    local t = now()
    if t - state.last_tick < settings.tick then return end
    state.last_tick = t
    crash.guard('main loop', tick)()
    if state.profile and t - state.profile_sent > 15 then crash.guard('sending the setup to the app', send_profile)() end
    -- talking to the app: a problem here is reported once a minute (crash report), not every second in chat
    crash.guard('talking to Vanguard Control', bridge.poll)(settings, state)
end)

------------------------------------------------------------------------
-- Events: party buffs, actions, chat, zoning
------------------------------------------------------------------------
windower.register_event('incoming chunk', function(id, data)
    -- 0x02D "kill message": "<player> defeats <mob>", "<player> gains N experience / capacity points" (with the chain
    -- number). These never come through the 'action message' event, so kills / XP / CP / chains read 0 in his real game
    -- ("farming run saved (0 kills in 24 min)"). Reading what the game sent us - nothing is sent.
    if id == 0x02D then
        local actor, target = data:unpack('I', 0x04 + 1), data:unpack('I', 0x08 + 1)
        local p1, p2 = data:unpack('I', 0x10 + 1), data:unpack('I', 0x14 + 1)
        local msg = data:unpack('H', 0x18 + 1)
        stats.on_message(actor, target, msg, p1, p2)
        return
    end
    if id == 0x063 then bard.on_buff_packet(data) return end   -- our buffs with their end times (songs already up)
    if id == 0x0DC then                               -- party invite: inviter's name at 0x0C
        local player = windower.ffxi.get_player()
        local from = data:sub(0x0C + 1, 0x0C + 16):gsub('%z.*$', '')
        if player then party.on_invite(player, from) end
        return
    end
    if id ~= 0x076 then return end
    for k = 0, 4 do
        local pid = data:unpack('I', k * 48 + 5)
        if pid and pid ~= 0 then
            local list = {}
            for i = 1, 32 do
                local low = data:byte(k * 48 + 5 + 16 + i - 1)
                local high = math.floor(data:byte(k * 48 + 5 + 8 + math.floor((i - 1) / 4)) / 4 ^ ((i - 1) % 4)) % 4
                local buff = low + 256 * high
                if buff ~= 255 then list[#list + 1] = buff end
            end
            state.party_buffs[pid] = list
        end
    end
end)

local landed_msgs = S{2, 236, 237, 252, 264, 268, 271}
local resist_msgs = S{85, 284, 653, 654, 655, 656}
local buffed_msgs = S{230, 266, 280, 319}
local song_gone_msgs = { [64] = true, [204] = true, [206] = true, [350] = true, [531] = true }
local ko_msgs = { [6] = true, [20] = true, [97] = true, [113] = true, [406] = true, [605] = true, [646] = true }

windower.register_event('action message', function(actor_id, target_id, actor_index, target_index, message_id, p1, p2)
    stats.on_message(actor_id, target_id, message_id, p1, p2)
    local me = windower.ffxi.get_player()
    -- one of our songs wore off us / was dispelled (vg_bard keeps its song slots like Singer)
    if me and target_id == me.id and song_gone_msgs[message_id] then bard.on_lost(p1) end
    if me and target_id ~= me.id and (song_gone_msgs[message_id] or ko_msgs[message_id]) then
        local mb = windower.ffxi.get_mob_by_id(target_id)
        if mb and (not mb.is_npc or mb.spawn_type == 14) then
            if ko_msgs[message_id] then bard.on_member_ko(mb.name) else bard.on_member_lost(mb.name, p1) end
        end
    end
    local paused = me and engine.on_message(actor_id, message_id, me.id)
    if paused then log(paused) end
    farm.on_message(actor_id, target_id, message_id)
end)

windower.register_event('action', function(act)
    local player = windower.ffxi.get_player()
    if not player then return end
    local first = act.targets and act.targets[1]
    local first_action = first and first.actions and first.actions[1]
    mages.on_action(act, player, res)
    support.note_hate(act, player)

    -- Our own action results: release the busy lock, record songs / debuffs.
    if act.actor_id == player.id and act.category == 3 and first then           -- a weapon skill (Magian trials)
        local wsr = res.weapon_skills[act.param]
        if wsr then trials.note_ws(first.id, wsr.en) finish.note_ws(first.id, wsr.en) end
    end
    if act.actor_id == player.id then
        if act.category == 8 then
            if act.param == 28787 then state.busy_until = now() + 1 end       -- interrupted
        elseif act.category == 4 then
            state.busy_until = now() + 2.5
            local spell = res.spells[act.param]
            if spell then
                local on_me = false
                for _, t in ipairs(act.targets or {}) do if t.id == player.id then on_me = true end end
                if spell.type == 'BardSong' and on_me then bard.on_song(spell, player) end
                if spell.type == 'BardSong' and spell.status and not util.targets(spell, 'Enemy') then   -- on party members
                    for _, t in ipairs(act.targets or {}) do
                        local mb = t.id ~= player.id and windower.ffxi.get_mob_by_id(t.id)
                        if mb and (not mb.is_npc or mb.spawn_type == 14) then bard.on_member_song(spell, mb.name, player) end
                    end
                end
                if spell.type == 'Geomancy' and spell.en:sub(1, 4) == 'Geo-' then          -- where the luopan went down
                    state.geo_last = { name = spell.en, target = first and first.id, at = now() }
                end
                if first and first_action and state.debuffs[first.id] then
                    local rec = state.debuffs[first.id][spell.en]
                    if rec then
                        if landed_msgs:contains(first_action.message) then rec.landed = true share.debuff(first.id, spell.en, 'landed') end
                        if resist_msgs:contains(first_action.message) then log(spell.en .. ' resisted') rec.resisted, rec.other_until = true, nil share.debuff(first.id, spell.en, 'resisted') end
                    end
                end
            end
        elseif act.category == 3 or act.category == 6 or act.category == 5 then
            state.busy_until = now() + 1.5
            if act.category == 6 and first_action then
                local ja = res.job_abilities[act.param]
                if ja and (jobs.lucky[ja.en] or ja.en == 'Double-Up') then
                    engine.note_roll(ja.en, first_action.param)
                end
            end
        end
    end

    -- Weapon skills by anyone: advance our skillchain tracker.
    if act.category == 3 and first then
        local actor = windower.ffxi.get_mob_by_id(act.actor_id)
        local ws = res.weapon_skills[act.param]
        if actor and ws then
            local steps = sc_steps()
            local nxt = steps[state.sc.step + 1]
            if nxt and nxt.who == actor.name:lower() and nxt.ws:lower() == ws.en:lower() then
                state.sc = { target = first.id, step = state.sc.step + 1, time = now() }
                if state.sc.step >= #steps then state.sc = { target = 0, step = 0, time = 0 } end
            end
        end
    end

    -- Skillchain detection on any target -> open a burst window.
    if first and first_action and first_action.has_add_effect then
        local chain = util.skillchain_by_msg[first_action.add_effect_message]
        if chain then
            local bt = windower.ffxi.get_mob_by_target('bt')
            if not bt or bt.id == first.id then
                state.burst = { elements = util.burst_elements[chain] or {}, chain = chain,
                                expires = now() + settings.burst.window, target = first.id }
                bridge.log('Skillchain: ' .. chain)
            end
        end
    end

    -- Mob actions: buffs (for dispel) and readies/casts (for triggers).
    local actor = windower.ffxi.get_mob_by_id(act.actor_id)
    if actor and actor.is_npc and actor.spawn_type == 16 then
        local bt = windower.ffxi.get_mob_by_target('bt')
        if (act.category == 4 or act.category == 11) and first_action and buffed_msgs:contains(first_action.message)
            and bt and bt.id == act.actor_id then
            state.dispel_until = now() + 10
        end
        if act.category == 7 and first_action then
            local ab = res.monster_abilities[first_action.param] or res.weapon_skills[first_action.param]
            if ab then triggers.note_mob('readies', ab.en, actor.name) end
        elseif act.category == 8 and act.param == 24931 and first_action then
            local sp = res.spells[first_action.param]
            if sp then triggers.note_mob('casts', sp.en, actor.name) end
        end
    end
end)

windower.register_event('incoming text', function(original)
    if settings.modules.triggers then triggers.note_chat(original) end
    if settings.modules.farm then farm.on_text(original) end
    trials.on_text(original)
    local inviter = original:match('(%a+) invites you to')
    if inviter then
        local player = windower.ffxi.get_player()
        if player then party.on_invite(player, inviter) end
    end
end)

windower.register_event('zone change', function(new_id, old_id)
    local was_running = settings.enabled
    stop_running()
    warp.on_zone()
    farm.on_zone(new_id, old_id)
    state.party_buffs, state.debuffs, state.burst = {}, {}, nil
    state.sc = { target = 0, step = 0, time = 0 }
    state.busy_until = now() + 5
    state.farm_pulled, state.route, state.wp, state.resting = {}, nil, 1, false
    state.action_once = {}
    state.zone_push_until, state.zone_push = nil, nil
    if settings.pause_on_zone and was_running then
        settings.enabled = false
        settings.modules.farm = false
        store.save(settings)
        log('Stopped: changed zone (press Start / Run again when you want it)')
    end
end)

windower.register_event('ipc message', function(msg)
    local player = windower.ffxi.get_player()
    if not player then return end
    local to, from, text = msg:match('^vg_alert (%S+) ([^|]+)|(.+)$')
    if to then alts.on_alert(player, to, from, text) return end
    local frest = msg:match('^vg_farmrest (%S+)$')
    if frest then farm.on_rest_call(player, frest) return end
    local fmob, ffrom = msg:match('^vg_finish (%d+) (%S+)$')
    if fmob then finish.on_ipc(fmob, ffrom) return end
    local dmob, dspell, dwhat = msg:match('^vg_debuff (%d+) (.+) (%a+)$')
    if dmob then share.on_debuff(tonumber(dmob), dspell, dwhat) return end
    local cfrom, ctarget, csecs = msg:match('^vg_cure (%S+) (%S+) (%d+)$')
    if cfrom then share.on_cure(player, cfrom, ctarget, csecs) return end
    local gfrom, gwhat, garg = msg:match('^vg_gear (%S+) (%a+) (.+)$')
    if gfrom then safety.on_gear(player, gfrom, gwhat, garg) return end
    local xfrom, xwho, xcmd = msg:match('^vg_send (%S+) (%S+) (.+)$')
    if xfrom then share.on_send(player, xfrom, xwho, xcmd) return end
    local sfrom, ssub, sname = msg:match('^vg_setup (%S+) (%a+) ([%w_]+)$')
    if sfrom then team.on_setup(player, sfrom, ssub, sname) return end
    local mfrom2, mmode, monoff = msg:match('^vg_mode (%S+) (%a+) (%a+)$')
    if mfrom2 then team.on_mode(player, mfrom2, mmode, monoff) return end
    local lfrom, lflags = msg:match('^vg_lstate (%S+) ([01][01][01])$')
    if lfrom then travel.on_lstate(player, lfrom, lflags) return end
    local pfrom, px, py, pz, pzone = msg:match('^vg_pos (%S+) (%-?[%d.]+) (%-?[%d.]+) (%-?[%d.]+) (%d+)$')
    if pfrom then party.on_pos(player, pfrom, tonumber(px), tonumber(py), tonumber(pz), tonumber(pzone)) return end
    local sname, sleader, sjob, shp, smp, stp, sdist, sdo = msg:match('^vg_status (%S+) (%S+) (%S+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%S+)$')
    if sname then hud.on_status(player, sname, sleader, sjob, shp, smp, stp, sdist, sdo) return end
    local rfrom, rarg = msg:match('^vg_rolls (%S+) (%S+)$')
    if rfrom then support.on_rolls(player, rfrom, rarg, apply_rolls) return end
    local bfrom, bel, bst = msg:match('^vg_bar (%S+) (%a+) (%S+)$')
    if bfrom then mages.on_bar(player, bfrom, bel, bst) return end
    local slmob, slsecs = msg:match('^vg_sleep (%d+) (%d+)$')
    if slmob then mages.on_sleep(slmob, slsecs) return end
    local hname, hleader, hjob = msg:match('^vg_hello (%S+) (%S+) ?(%a*)$')
    if hname then
        party.on_hello(hname, hleader)
        if hjob ~= '' then mages.jobs[hname:lower()] = hjob end
        return
    end
    local ofrom, owhat, orest = msg:match('^vg_(%a+) (%S+) (.+)$')
    if owhat and (ofrom == 'hold' or ofrom == 'camp') then party.on_order(player, owhat, ofrom, orest) return end
    local mfrom, onoff = msg:match('^vg_mount (%S+) (%a+)$')
    if mfrom then alts.on_mount(player, mfrom, onoff) return end
    local all = msg:match('^vg_all (.+)$')
    if all then windower.send_command('vg ' .. all) return end
    local who, cmd = msg:match('^vg_to (%S+) (.+)$')
    if who and who:lower() == player.name:lower() then windower.send_command('vg ' .. cmd) end
end)

-- the farming key (picked in the app): starts / stops / resumes farming from the game window
local FARM_KEYS = { ['^f8'] = true, ['^f9'] = true, ['^f10'] = true, ['!f9'] = true }
local function farm_key(on, key)
    key = key or settings.farm.hotkey
    if key and FARM_KEYS[key] then windower.send_command(on and ('bind %s vg farming toggle'):format(key) or ('unbind ' .. key)) end
end

windower.register_event('load', function()
    bridge.start(settings)
    if settings.keys then bind_keys(true) end
    quick.hk_bind_all(true)
    farm_key(true)
    if windower.ffxi.get_info().logged_in then load_profile() bard.read_last_buffs() end
    update.on_load()
end)
windower.register_event('login', function() coroutine.schedule(function() load_profile() end, 5) end)
windower.register_event('job change', function()
    -- his request: stop the bot when the job changes (main or sub)
    if settings.stop_on_job and (settings.enabled or settings.modules.farm) then
        local player = windower.ffxi.get_player()
        if settings.modules.farm then farm.send_run(player, 'changed job') farm.treasure(false) end
        settings.enabled, settings.modules.farm = false, false
        stop_running()
        store.save(settings)
        log('Stopped: changed job (press Start / Run again when you want it)')
        coroutine.schedule(function() load_profile() settings.modules.farm = false end, 2)
        return
    end
    coroutine.schedule(function() load_profile() end, 2)
end)
windower.register_event('unload', function()
    -- running (or farming) when unloaded: carry on if it's loaded again within 90 s (a reload)
    settings.resume_until = settings.enabled and (os.time() + 90) or 0
    pcall(store.save, settings)
    stop_running() bridge.stop() hud.destroy()
    if settings.keys then bind_keys(false) end
    quick.hk_bind_all(false)
    farm_key(false)
end)

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
-- Hotkeys for alt orders on the leader (Byrth's dualboxing guide: one key per order). Windower binds only.
local KEYS = {
    { '^f1', 'vg holdtoggle', 'hold / come' }, { '^f2', 'vg retreat', 'retreat' }, { '^f3', 'vg camptoggle', 'camp here / camp off' },
    { '^f4', 'vg party', 'invite the alts' }, { '^f5', 'vg all toggle', 'start / stop everyone' }, { '^f6', 'vg hud', 'show / hide the alt box' },
    { '^f7', 'vg defensetoggle', 'alts defense set on / off' },
}
local function bind_keys(on)
    for _, k in ipairs(KEYS) do windower.send_command(on and ('bind %s %s'):format(k[1], k[2]) or ('unbind %s'):format(k[1])) end
end

local presets = {
    melee  = {follow = true, assist = true, ws = true},
    healer = {follow = true, heal = true, raise = true, cleanse = true, buffs = true},
    bard   = {follow = true, songs = true, debuff = true},
    geo    = {follow = true, geo = true, buffs = true},
    nuker  = {follow = true, burst = true, debuff = true, buffs = true},
    farmer = {assist = true, ws = true, rest = true, trusts = true, farm = true, triggers = true},
    curer  = {follow = true, heal = true, raise = true, cleanse = true, buffs = true, mana = true, rest = true},
}

local function set_value(path, value)
    local section, key = path:match('^([%w_]+)%.([%w_]+)$')
    local tbl = section and settings[section] or settings
    key = key or path
    if tbl[key] == nil then return false end
    local current = tbl[key]
    if type(current) == 'number' then value = tonumber(value) or current
    elseif type(current) == 'boolean' then value = (value == 'true' or value == 'on')
    end
    tbl[key] = value
    return true
end

local help = [[Vanguard commands (//vg ...):
  Vanguard sets itself up for your job automatically. Usually you only need:
  leader <name> | role <role> | ws <weapon skill> | action <id> on|off | on | off
  reset                             go back to the job's recommended setup
  on | off | status | save
  leader <name>                     who to follow and assist
  <module> on|off|toggle            follow assist heal raise cleanse buffs ws sc burst songs geo
                                    debuff dispel triggers rest mana trusts farm
  preset melee|healer|bard|geo|nuker|farmer|curer|none
  route record | stop | clear | show  record a farming route by walking it
  set <section.key> <value>         e.g. set ws.name Savage Blade | set heal.cure_at 70
  trigger add <rule> | trigger list | trigger clear
  bar <element> [status] | off      keep Bar-element + Bar-status up (leader: on every alt)
  sleep on|off                      sleep extra mobs that attack the party
  warp                              warp home (Warp spell, Instant Warp or Warp Ring)
  rolls melee|magic|accuracy|...    Corsair roll set (leader: sent to the Corsair)
  pianissimo <song> > <name>|clear  Bard single-target songs
  chain <skillchain>|off            Scholar Immanence skillchains (liquefaction, fusion, ...)
  update [install|on|off]           check for / install a newer Vanguard from its GitHub page
  reload                            reload Vanguard (the panel does this after updating it)
  all <command>                     run a vg command on every character
  to <name> <command>               run a vg command on one character]]

windower.register_event('addon command', function(cmd, ...)
    cmd = cmd and cmd:lower() or 'help'
    local args = {...}
    local rest = table.concat(args, ' ')

    if cmd == 'on' or cmd == 'off' then
        settings.enabled = (cmd == 'on')
        if not settings.enabled then stop_running() end
        log(settings.enabled and 'enabled' or 'disabled')
    elseif cmd == 'toggle' then
        windower.send_command('vg ' .. (settings.enabled and 'off' or 'on'))
    elseif cmd == 'leader' then
        settings.leader = args[1] or ''
        if settings.leader:lower() == 'none' then settings.leader = '' end
        store.save(settings)
        log('leader: ' .. (settings.leader ~= '' and settings.leader or 'none'))
        send_profile()
    -- "ws <weapon skill>" (the app's Weapon skill menu) sets the weapon skill; only "ws on|off|toggle" is the module
    -- switch. (It used to land here and switch weapon skills OFF: "ws Atonement" -> "ws: off".)
    elseif settings.modules[cmd] ~= nil and not (cmd == 'ws'
            and not (args[1] and ({ on = 1, off = 1, toggle = 1, ['true'] = 1, ['false'] = 1 })[args[1]:lower()])) then
        local v = (args[1] or 'toggle'):lower()
        if v == 'toggle' then settings.modules[cmd] = not settings.modules[cmd]
        else settings.modules[cmd] = (v == 'on' or v == 'true') end
        if cmd == 'follow' and not settings.modules.follow then stop_running() end
        log(cmd .. ': ' .. (settings.modules[cmd] and 'on' or 'off'))
        save_profile()
        send_profile()
    elseif cmd == 'alerts' or cmd == 'mountsync' or cmd == 'upkeep' or cmd == 'hud' or cmd == 'stealth' or cmd == 'restsync' then
        local key = (cmd == 'mountsync') and 'mount' or cmd
        local v = (args[1] or 'toggle'):lower()
        if v == 'toggle' then settings.alts[key] = not settings.alts[key] else settings.alts[key] = (v == 'on') end
        store.save(settings)
        log(cmd .. ': ' .. (settings.alts[key] and 'on' or 'off'))
    elseif cmd == 'party' then
        if (args[1] or ''):lower() == 'accept' then
            settings.party.accept = ((args[2] or 'on'):lower() == 'on')
            store.save(settings)
            log('Party: accept invites ' .. (settings.party.accept and 'on' or 'off'))
        else
            party.invite_all(windower.ffxi.get_player())
        end
    elseif cmd == 'formation' then
        local f = (args[1] or ''):lower()
        if f == 'spread' or f == 'line' or f == 'off' then
            settings.follow.formation = f
            store.save(settings)
            log('Formation: ' .. f)
        else log('Formation: ' .. settings.follow.formation .. ' (//vg formation spread|line|off)') end
    elseif cmd == 'defense' or cmd == 'defensetoggle' then
        safety.defense(windower.ffxi.get_player(), cmd == 'defensetoggle' and 'toggle' or args[1])
    elseif cmd == 'gs' then
        safety.gs(windower.ffxi.get_player(), rest)
    elseif cmd == 'update' then
        update.command(args)
    elseif cmd == 'dump' then
        local player = windower.ffxi.get_player()
        if player then bridge.send({ type = 'dump', name = player.name, data = link.dump(player) }) end
    elseif cmd == 'curetier' or cmd == 'curagatier' then
        local val = table.remove(args)
        local name = table.concat(args, ' ')
        local sp = util.spell(name)
        local family = cmd == 'curetier' and '^Cure' or '^Curaga'
        if not sp or not sp.en:find(family) or (cmd == 'curetier' and sp.en:find('^Curaga')) then
            log('Usage: //vg curetier Cure IV 650|off   //vg curagatier Curaga III on|off')
        elseif cmd == 'curetier' then
            local DEFAULT = { Cure = 70, ['Cure II'] = 170, ['Cure III'] = 350, ['Cure IV'] = 650, ['Cure V'] = 1000, ['Cure VI'] = 1300 }
            local t, order = {}, { 'Cure VI', 'Cure V', 'Cure IV', 'Cure III', 'Cure II', 'Cure' }
            for _, e in ipairs(util.split(settings.heal.tiers or '', ',')) do
                local n, hp = e:match('^(.-)%s*:%s*(%d+)$')
                if n then t[n] = tonumber(hp) end
            end
            t[sp.en] = (val == 'off') and 0 or (val == 'on' and DEFAULT[sp.en]) or tonumber(val) or t[sp.en] or DEFAULT[sp.en]
            local out = {}
            for _, n in ipairs(order) do out[#out + 1] = ('%s:%d'):format(n, t[n] or DEFAULT[n]) end
            settings.heal.tiers = table.concat(out, ',')
            store.save(settings) send_profile()
        else
            local out = {}
            for _, n in ipairs(util.split(settings.heal.curagas or '', ',')) do
                if n:lower() ~= sp.en:lower() then out[#out + 1] = n end
            end
            if val == 'on' then out[#out + 1] = sp.en end
            settings.heal.curagas = table.concat(out, ',')
            store.save(settings) send_profile()
        end
    elseif cmd == 'stratspell' then
        -- from the panel's Stratagems tab: //vg stratspell <list> on|off <spell>  |  //vg stratspell <list> clear
        local list, what = (args[1] or ''):lower(), (args[2] or ''):lower()
        local ok, why = strat.toggle(list, what, table.concat(args, ' ', 3))
        if ok then
            store.save(settings)
            send_profile()
        else
            log('Stratagem list: ' .. tostring(why))
        end
    elseif cmd == 'actmove' then
        -- the app's priority arrows: //vg actmove <id> up|down|top|bottom   |   //vg actmove reset
        local pr = state.profile
        local id, how = args[1], (args[2] or ''):lower()
        if id == 'reset' then id, how = '', 'reset' end
        if pr and engine.move(pr.job, pr, id, how) then
            save_profile()
            send_profile()
        end
    elseif cmd == 'actopt' then
        if link.actopt(state.profile, args[1], args[2], args[3]) then
            save_profile()
            send_profile()
        end
    elseif cmd == 'hotkey' then
        -- from the app: //vg hotkey set <key> <who> <kind> <target> [name]  |  //vg hotkey clear <key>
        local sub, key = (args[1] or ''):lower(), args[2]
        local ok = false
        if sub == 'set' then ok = quick.hk_set(key, args[3], args[4], args[5], table.concat(args, ' ', 6))
        elseif sub == 'clear' then ok = quick.hk_clear(key) end
        if ok then store.save(settings) send_profile() log(('Hotkey %s %s'):format(key, sub == 'set' and 'set' or 'cleared'))
        else log('Hotkey: not changed') end
    elseif cmd == 'nearby' then
        -- the app's "Look around": mobs near this character, grouped by name
        local player = windower.ffxi.get_player()
        if player then bridge.send({ type = 'nearby', name = player.name, mobs = quick.nearby(50) }) end
    elseif cmd == 'farmlist' then
        if quick.farmlist((args[1] or ''):lower(), (args[2] or ''):lower(), table.concat(args, ' ', 3)) then
            store.save(settings)
            send_profile()
        end
    elseif cmd == 'hk' then
        quick.hk_press(windower.ffxi.get_player(), args[1])
    elseif cmd == 'warp' then
        -- the app's Go home box: warp home with the best way this character has (vg_warp)
        local player = windower.ffxi.get_player()
        if player then stop_running() warp.go(player) end
    elseif cmd == 'logout' then
        -- the app's stop timer: the normal /logout (the game counts down and can be cancelled by moving)
        stop_running()
        log('Logging out (stop timer)')
        windower.send_command('input /logout')
    elseif cmd == 'act' then
        -- a quick button from the app: //vg act <ma|ja|ws|item|attack|follow|stop> <bt|t|me|leader|Name> [name]
        local player = windower.ffxi.get_player()
        local done, why = quick.act(player, args[1], args[2], table.concat(args, ' ', 3))
        if not done then log('Quick button: ' .. tostring(why)) end
    elseif cmd == 'stats' then
        if (args[1] or ''):lower() == 'reset' then stats.reset() log('Session stats reset') end
        local t = stats.get()
        log(('Session %d min: %d XP, %d CP, %d LP, %d kills, %d deaths'):format(math.floor(t.secs / 60), t.exp, t.cp, t.lp, t.kills, t.deaths))
    elseif cmd == 'reload' then
        log('Reloading Vanguard...')
        windower.send_command('lua reload vanguard')
    elseif cmd == 'rolls' then
        support.rolls(windower.ffxi.get_player(), rest, apply_rolls)
    elseif cmd == 'pianissimo' then
        if (args[1] or ''):lower() == 'set' then
            -- from the panel: //vg pianissimo set <name> <1|2> <song|none>
            if bard.pian_set(args[2], args[3], table.concat(args, ' ', 4)) then store.save(settings) send_profile() end
        elseif support.set_pianissimo(rest) then store.save(settings) send_profile() end
    elseif cmd == 'resing' then
        -- //vg resing: sing every song again now (the panel's "Sing all songs again now")
        state.redo_at = now()
        log('Songs: singing them all again')
    elseif cmd == 'dummy' then
        -- //vg dummy <1|2|3> <song|none>  (3 dummies open slots 3-5: Daurdabla + Clarion Call)
        local slot, song = tonumber(args[1]), table.concat(args, ' ', 2)
        local sp = util.spell(song)
        if slot and slot >= 1 and slot <= 3 and (song == 'none' or (sp and sp.type == 'BardSong')) then
            local d = util.split(settings.songs.dummy, ',')
            d[slot] = sp and sp.en or nil
            local out = {}
            for i = 1, 3 do if d[i] then out[#out + 1] = d[i] end end
            settings.songs.dummy = table.concat(out, ',')
            store.save(settings) send_profile()
            log('Dummy songs: ' .. (settings.songs.dummy ~= '' and settings.songs.dummy or 'none'))
        else
            log('Usage: //vg dummy 1|2|3 <song|none>   e.g. //vg dummy 1 Knight\'s Minne')
        end
    elseif cmd == 'songrange' then
        -- //vg songrange <name> on|off : wait for this member to be within 10' before party songs
        local name, v = args[1], (args[2] or 'on'):lower()
        if name then
            local out = {}
            for _, n in ipairs(util.split(settings.songs.aoe_names, ',')) do if n:lower() ~= name:lower() then out[#out + 1] = n end end
            if v == 'on' then out[#out + 1] = name end
            settings.songs.aoe_names = table.concat(out, ',')
            store.save(settings) send_profile()
        end
    elseif cmd == 'bar' then
        if mages.set_bar(windower.ffxi.get_player(), args[1], args[2]) then store.save(settings) end
    elseif cmd == 'sleep' then
        local v = (args[1] or 'toggle'):lower()
        if v == 'toggle' then settings.mages.sleep = not settings.mages.sleep else settings.mages.sleep = (v == 'on' or v == 'true') end
        store.save(settings)
        log('Sleep extra mobs: ' .. (settings.mages.sleep and 'on' or 'off'))
    elseif cmd == 'chain' then
        if mages.set_chain(args[1]) then store.save(settings) end
    elseif cmd == 'send' or cmd == 'sendall' then
        share.send(windower.ffxi.get_player(), cmd == 'send' and '*' or '**', rest)
    elseif cmd == 'sendto' then
        local who = table.remove(args, 1)
        share.send(windower.ffxi.get_player(), who or '?', table.concat(args, ' '))
    elseif cmd == 'setup' then
        team.command(windower.ffxi.get_player(), args[1], args[2])
    elseif cmd == 'exp' or cmd == 'cp' or cmd == 'ep' then
        team.exp(windower.ffxi.get_player(), args)
    elseif cmd == 'keys' then
        local v = (args[1] or 'on'):lower()
        settings.keys = (v == 'on')
        store.save(settings)
        bind_keys(settings.keys)
        if settings.keys then
            log('Hotkeys on:')
            for _, k in ipairs(KEYS) do log(('  Ctrl+%s  %s'):format(k[1]:sub(2):upper(), k[3])) end
        else log('Hotkeys off') end
    elseif cmd == 'holdtoggle' then
        party.order(windower.ffxi.get_player(), state.hold_sent and 'come' or 'hold')
        state.hold_sent = not state.hold_sent
    elseif cmd == 'camptoggle' then
        party.order(windower.ffxi.get_player(), 'camp', state.my_camp and 'off' or '')
    elseif cmd == 'retreat' then
        party.order(windower.ffxi.get_player(), 'retreat')
    elseif cmd == 'hold' or cmd == 'come' then
        party.order(windower.ffxi.get_player(), cmd)
    elseif cmd == 'camp' then
        party.order(windower.ffxi.get_player(), 'camp', (args[1] or ''):lower())
    elseif cmd == 'food' then
        settings.upkeep.food = (rest:lower() == 'off') and '' or rest
        store.save(settings)
        log(settings.upkeep.food ~= '' and ('Food upkeep: ' .. settings.upkeep.food) or 'Food upkeep off')
        send_profile()
    elseif cmd == 'reraise' then
        settings.upkeep.reraise = (rest:lower() == 'off') and '' or rest
        store.save(settings)
        log(settings.upkeep.reraise ~= '' and ('Reraise upkeep: ' .. settings.upkeep.reraise) or 'Reraise upkeep off')
        send_profile()
    elseif cmd == 'preset' then
        local p = presets[(args[1] or ''):lower()]
        for k in pairs(settings.modules) do settings.modules[k] = p and p[k] or false end
        log('preset: ' .. (args[1] or 'none'))
    elseif cmd == 'set' then
        local path = table.remove(args, 1)
        if path and set_value(path, table.concat(args, ' ')) then
            log(path .. ' = ' .. table.concat(args, ' '))
            save_profile()
            send_profile()
        else
            log('unknown setting: ' .. tostring(path))
        end
    elseif cmd == 'trigger' then
        local sub = (table.remove(args, 1) or 'list'):lower()
        if sub == 'add' then
            local n = 1
            while settings.triggers['t' .. n] and settings.triggers['t' .. n] ~= '' do n = n + 1 end
            settings.triggers['t' .. n] = table.concat(args, ' ')
            log('trigger t' .. n .. ' added')
            store.save(settings) send_profile()
        elseif sub == 'del' then
            -- the app's x on a reaction: //vg trigger del t3
            local key = args[1] or ''
            if key:match('^t%d+$') and settings.triggers[key] then
                settings.triggers[key] = ''
                log('trigger ' .. key .. ' removed')
                store.save(settings) send_profile()
            end
        elseif sub == 'clear' then
            settings.triggers = { t1 = '' }
            log('triggers cleared')
            store.save(settings) send_profile()
        else
            for k, v in pairs(settings.triggers) do
                -- (a removed reaction comes back from settings.xml as an empty table - see vg_trials' decode)
                if type(v) == 'string' and v ~= '' then windower.add_to_chat(207, ('  %s: %s'):format(k, v)) end
            end
        end
    elseif cmd == 'all' then
        windower.send_ipc_message('vg_all ' .. rest)
        windower.send_command('vg ' .. rest)
    elseif cmd == 'to' then
        local who = table.remove(args, 1)
        if who then windower.send_ipc_message('vg_to ' .. who .. ' ' .. table.concat(args, ' ')) end
    elseif cmd == 'role' then
        local r = (args[1] or ''):lower()
        local player = windower.ffxi.get_player()
        local ok = false
        for _, x in ipairs(jobs.roles_for(player.main_job)) do if x == r then ok = true end end
        if ok then
            local pr = { job = player.main_job, role = r, ws = state.profile and state.profile.ws or default_ws(player.main_job), toggles = {} }
            apply_profile(pr)
            save_profile()
            log('Role: ' .. (jobs.role_labels[r] or r))
            send_profile(player)
        else
            log('Roles for ' .. player.main_job .. ': ' .. table.concat(jobs.roles_for(player.main_job), ', '))
        end
    elseif cmd == 'action' then
        local id, v = args[1], (args[2] or 'toggle'):lower()
        if state.profile and id then
            local cur = false
            for _, a in ipairs(jobs.actions_for(state.profile.job)) do
                if a.id == id then cur = engine.enabled(a, state.profile) end
            end
            if v == 'toggle' then state.profile.toggles[id] = not cur
            else state.profile.toggles[id] = (v == 'on' or v == 'true') end
            save_profile()
            send_profile()
        end
    elseif cmd == 'ws' then
        local name = table.concat(args, ' ')
        if name:lower() == 'none' then name = '' end
        local w = name ~= '' and util.wskill(name)
        if w then name = w.en end
        settings.ws.name = name
        if state.profile then state.profile.ws = name end
        settings.modules.ws = name ~= ''
        save_profile()
        log('Weapon skill: ' .. (name ~= '' and name or 'off'))
        send_profile()
    elseif cmd == 'profile' then
        send_profile()
    elseif cmd == 'menu' then
        local msg = menu.command(settings, args, windower.ffxi.get_player())
        if msg then
            log(msg)
            save_profile()
            send_profile()
        else
            log('menu: buff <who> on|off <spell> | song <slot> <song|none> | debuff on|off <spell> | '
                .. 'indi|geo <spell|none> | geotarget bt|me|<name> | entrust <who|none> <spell> | '
                .. 'heal|priority <who> on|off | cleanse on|off <status>')
        end
    elseif cmd == 'autosetup' or cmd == 'reset' then
        load_profile(nil, cmd == 'reset')
        save_profile()
    elseif cmd == 'farming' then
        -- The app's Start / Stop farming: everything farming needs in one click.
        local sub = (args[1] or ''):lower()
        if sub == 'start' then
            for _, m in ipairs({ 'farm', 'ws', 'rest', 'actions' }) do settings.modules[m] = true end
            if settings.trusts.list ~= '' then settings.modules.trusts = true end
            settings.enabled = true
            farm.start(windower.ffxi.get_player(), windower.ffxi.get_mob_by_target('me'))
            farm.share_camp(windower.ffxi.get_player(), true)
            if settings.farm.mode == 'list' and #util.split(settings.farm.targets, ',') == 0 then log('Farming on, but no mobs are picked yet: pick what to fight') else log('Farming started') end
        elseif sub == 'stop' then
            farm.forget_rezone()
            farm.send_run(windower.ffxi.get_player(), 'stopped by you')
            farm.treasure(false)
            settings.modules.farm, settings.enabled = false, false
            stop_running()
            if settings.farm.pull_back then farm.share_camp(windower.ffxi.get_player(), false) end
            log('Farming stopped')
        elseif sub == 'toggle' then
            -- the farming key: stop when farming, resume when paused, else start
            local r = state.farm_run
            if settings.modules.farm and settings.enabled then windower.send_command('vg farming stop')
            elseif settings.modules.farm and r and r.paused then windower.send_command('vg farming resume')
            else windower.send_command('vg farming start') end
            return
        elseif sub == 'pause' then
            farm.pause(true) log('Farming paused')
        elseif sub == 'resume' then
            farm.pause(false) log('Farming resumed')
        elseif sub == 'quick' then
            -- "Quick start": farm the most common unclaimed mob within 30 yalms, camp here, go
            local best, ignored = nil, {}
            for _, n in ipairs(util.split(settings.farm.ignore, ',')) do ignored[n:lower()] = true end
            for _, m in ipairs(quick.nearby(30)) do
                local free = m.c - (m.others or 0)
                if free > 0 and not ignored[m.n:lower()] and (not best or free > best.free) then
                    best = { n = m.n, free = free }
                end
            end
            if not best then
                log('Quick start: no unclaimed mobs within 30 yalms')
            else
                local me = windower.ffxi.get_mob_by_target('me')
                settings.farm.mode, settings.farm.area, settings.farm.targets = 'list', 'camp', best.n
                if me then farm.set_camp(me) end
                for _, m in ipairs({ 'farm', 'ws', 'rest', 'actions' }) do settings.modules[m] = true end
                if settings.trusts.list ~= '' then settings.modules.trusts = true end
                settings.enabled = true
                farm.start(windower.ffxi.get_player(), me)
                farm.share_camp(windower.ffxi.get_player(), true)
                log(('Quick start: farming %s (%d around), camp here'):format(best.n, best.free))
            end
        elseif sub == 'report' then
            state.farm_report = {}                                  -- "Clear" on the mob report
            log('Mob report cleared')
        elseif sub == 'camp' then
            -- "Set camp here"
            local me = windower.ffxi.get_mob_by_target('me')
            if me then farm.set_camp(me) settings.farm.area = 'camp' log('Camp set here') if settings.modules.farm then farm.share_camp(windower.ffxi.get_player(), true) end end
        end
        save_profile() send_profile()   -- (the job setup carries the module switches a reload restores)
    elseif cmd == 'trial' then
        -- the Farming tab's Magian trials: //vg trial add <kind>|<goal>|<weapon skill>|<mobs> | del <t1> | reset <t1> | assist <t1>
        local sub, rest = (args[1] or ''):lower(), table.concat(args, ' ', 2)
        if sub == 'add' then
            local k = trials.add(rest)
            log(k and 'Magian trial added' or 'That trial could not be added (pick a weapon skill for a weapon skill trial)')
        elseif sub == 'del' then trials.remove(rest)
        elseif sub == 'reset' then trials.reset(rest)
        elseif sub == 'assist' then trials.assist(rest) end
        save_profile() send_profile()
    elseif cmd == 'farmemergency' then
        -- the Farming tab's emergency menu: //vg farmemergency item <name> | ja <name> | none
        local kind, name = (args[1] or 'none'):lower(), table.concat(args, ' ', 2)
        local cmdline = ''
        if kind == 'ja' and util.ability(name) then cmdline = ('input /ja "%s" <me>'):format(util.ability(name).en)
        elseif kind == 'item' and name ~= '' then
            for _, it in pairs(require('resources').items) do
                if type(it) == 'table' and it.en and it.en:lower() == name:lower() then cmdline = ('input /item "%s" <me>'):format(it.en) break end
            end
        end
        settings.farm.emergency = cmdline
        log(cmdline ~= '' and ('Emergency: ' .. cmdline) or 'No emergency action')
        save_profile() send_profile()
    elseif cmd == 'farmwatch' then
        -- the Farming tab's drop alert: //vg farmwatch add|remove <item> | clear
        local sub, name = (args[1] or ''):lower(), table.concat(args, ' ', 2)
        local keep = {}
        if sub ~= 'clear' then
            for _, n in ipairs(util.split(settings.farm.watch, ',')) do if n:lower() ~= name:lower() then keep[#keep + 1] = n end end
        end
        if sub == 'add' and farm.item_id(name) then keep[#keep + 1] = require('resources').items[farm.item_id(name)].en end
        settings.farm.watch = table.concat(keep, ',')
        log('Drop alert for: ' .. (settings.farm.watch ~= '' and settings.farm.watch or 'nothing'))
        save_profile() send_profile()
    elseif cmd == 'farmkey' then
        -- the Farming tab's key menu: //vg farmkey ^f9 | off
        local key = (args[1] or 'off'):lower()
        farm_key(false)
        settings.farm.hotkey = FARM_KEYS[key] and key or ''
        farm_key(true)
        log(settings.farm.hotkey ~= '' and ('Farming key: ' .. settings.farm.hotkey:gsub('%^', 'Ctrl+'):gsub('!', 'Alt+'):upper()) or 'No farming key')
        save_profile() send_profile()
    elseif cmd == 'farmitem' then
        -- the Farming tab's "Farm for": //vg farmitem <item name> | none
        local name = table.concat(args, ' ')
        local id = farm.item_id(name)
        settings.farm.item = id and require('resources').items[id].en or ''
        if settings.farm.item == '' then settings.farm.item_goal = 0
        elseif settings.farm.item_goal <= 0 then settings.farm.item_goal = 12 end
        log(settings.farm.item ~= '' and ('Farming for %d %s'):format(settings.farm.item_goal, settings.farm.item) or 'Not farming for an item')
        store.save(settings) send_profile()
    elseif cmd == 'farmpreset' then
        -- the Farming tab's presets: //vg farmpreset party | items | safe | clear
        local name = (args[1] or ''):lower()
        if farm.preset(name) then
            log('Farming preset: ' .. ({ party = 'XP / CP party', items = 'item farming', safe = 'safe and careful', clear = 'clear everything nearby' })[name])
        end
        save_profile() send_profile()   -- (the job setup carries the module switches a reload restores)
    elseif cmd == 'farmstrong' then
        -- the "too strong" list on the Farming tab: //vg farmstrong remove <name> | clear
        local sub, name = (args[1] or ''):lower(), table.concat(args, ' ', 2)
        local keep = {}
        if sub ~= 'clear' then
            for _, n in ipairs(util.split(settings.farm.strong, ',')) do if n:lower() ~= name:lower() then keep[#keep + 1] = n end end
        end
        settings.farm.strong = table.concat(keep, ',')
        log(sub == 'clear' and 'Too strong list cleared' or ('Will fight ' .. name .. ' again'))
        store.save(settings) send_profile()
    elseif cmd == 'farmspot' then
        -- the Farming tab's spots: //vg farmspot save | load <s1> | del <s1>
        local sub, key = (args[1] or ''):lower(), args[2] or ''
        if sub == 'save' then farm.save_spot()
        elseif sub == 'load' then if farm.load_spot(key) then state.farm_spot = key end
        elseif sub == 'del' then farm.delete_spot(key)
        elseif sub == 'import' then farm.import_spot(table.concat(args, ' ', 2)) end
        store.save(settings) send_profile()
    elseif cmd == 'radar' then
        -- the Farming tab is open: send the radar for a few seconds
        state.radar_until = os.clock() + 6
    elseif cmd == 'finish' then
        -- the app's "Finish the mob with" menu: //vg finish <weapon skill> | none
        local name = table.concat(args, ' ')
        local ws = util.wskill(name)
        settings.ws.finish = ws and ws.en or ''
        log(settings.ws.finish ~= '' and ('Finish mobs with %s %s'):format(settings.ws.finish, settings.ws.finish_at > 0 and ('under ' .. settings.ws.finish_at .. '% HP') or 'when one hit would kill them (learned)') or 'No finishing weapon skill')
        store.save(settings) send_profile()
    elseif cmd == 'trustlist' then
        -- the Farming tab's trust picker: //vg trustlist add|remove <trust> | clear
        local sub, name = (args[1] or ''):lower(), table.concat(args, ' ', 2)
        local list = util.split(settings.trusts.list, ',')
        local keep = {}
        for _, n in ipairs(list) do if n:lower() ~= name:lower() then keep[#keep + 1] = n end end
        if sub == 'add' and util.spell(name) and util.spell(name).type == 'Trust' then keep[#keep + 1] = util.spell(name).en end
        if sub == 'clear' then keep = {} end
        settings.trusts.list = table.concat(keep, ',')
        settings.modules.trusts = settings.trusts.list ~= '' and (settings.modules.trusts or settings.modules.farm)
        log('Trusts: ' .. (settings.trusts.list ~= '' and settings.trusts.list or 'none'))
        store.save(settings) send_profile()
    elseif cmd == 'farmpull' then
        -- How to pull, picked from a menu: //vg farmpull none | ra | ja <ability> | ma <spell>
        local kind, name = (args[1] or 'none'):lower(), table.concat(args, ' ', 2)
        if kind == 'ra' then settings.farm.pull_cmd = 'input /ra <t>'
        elseif kind == 'ja' and util.ability(name) then settings.farm.pull_cmd = ('input /ja "%s" <t>'):format(util.ability(name).en)
        elseif kind == 'ma' and util.spell(name) then settings.farm.pull_cmd = ('input /ma "%s" <t>'):format(util.spell(name).en)
        else settings.farm.pull_cmd = '' end
        log('Pull with: ' .. (settings.farm.pull_cmd ~= '' and settings.farm.pull_cmd or 'walk up and attack'))
        store.save(settings) send_profile()
    elseif cmd == 'route' then
        local sub = (args[1] or 'show'):lower()
        if sub == 'record' then
            state.recording, state.recording_pts = true, {}
            log('Recording route: walk the path, then //vg route stop')
        elseif sub == 'stop' then
            state.recording = false
            local parts = {}
            for _, p in ipairs(state.recording_pts or {}) do
                parts[#parts + 1] = ('%.1f:%.1f:%.1f'):format(p.x, p.y, p.z)
            end
            settings.farm.route = table.concat(parts, ';')
            state.route, state.wp = nil, 1
            store.save(settings) send_profile()
            log(('Route saved with %d points'):format(#parts))
        elseif sub == 'clear' then
            settings.farm.route, state.route, state.wp = '', nil, 1
            store.save(settings) send_profile()
            log('Route cleared')
        else
            local n = #util.split(settings.farm.route, ';')
            log(('Route: %d waypoints%s'):format(n, state.recording and ' (recording)' or ''))
        end
    elseif cmd == 'save' then
        store.save(settings)
        log('settings saved')
    elseif cmd == 'status' then
        local on = {}
        for k, v in pairs(settings.modules) do if v then on[#on + 1] = k end end
        table.sort(on)
        log(('%s | leader: %s | modules: %s'):format(settings.enabled and 'ON' or 'OFF',
            settings.leader ~= '' and settings.leader or 'none', #on > 0 and table.concat(on, ', ') or 'none'))
    else
        for line in help:gmatch('[^\n]+') do windower.add_to_chat(207, line) end
    end
end)

-- Expose for the bridge (state snapshots).
_G.vanguard_settings = function() return settings end
