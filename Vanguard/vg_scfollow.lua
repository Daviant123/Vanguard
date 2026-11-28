--[[
Vanguard: reactive skillchains (1.2.0, Silmaril audit items 1.2 + 3.2). Our own code; the audit describes behaviour only.

Up to 4 rules per job: "when <who> makes <trigger> on the mob we fight, use <my weapon skill> after <delay> s".
  who      a character name, or 'anyone'
  trigger  a weapon skill (Savage Blade), a spell (an Immanence opener, e.g. Fire) or a skillchain property
           (Light, Darkness, Fusion, ...: the skillchain message seen on the mob, made by anyone / by that person)
  ws       my weapon skill
  delay    seconds after the trigger lands (kept between 2 s and the learned window, see below)
  scf_rules[job] = "who|trigger|ws|delay;who|trigger|ws|delay;..."   (//vg scf add | list | clear | on | off)
  scf.on   the module switch (default off)

Fed by Vanguard's 'action' handler (only reads what the game sends: cat 3 weapon skills, cat 4 spells, the skillchain
add-effect message via util.skillchain_by_msg). Only the mob we fight (battle target), only with 1000+ TP, a weapon skill
the weapon in hand can use (util.ws_fits), in reach. One trigger = one weapon skill: a trigger leaves one pending
follow-up for that mob, used once (a newer trigger on the same mob replaces it - the chain moved on).

Who owns the TP (one owner per action):
  1. sc.steps (fixed skillchain steps, modules.sc on) wins for a character listed in it: such a character never follows
     rules at all, so the two never fight over TP.
  2. Otherwise a pending follow-up owns the TP from the trigger until it is used or its window ran out: do_ws (finisher,
     Aftermath, battle lists, AutoSkillchain / wschain, the normal weapon skill) holds meanwhile (scf.owns_tp) and
     scf.tick runs right after do_skillchain, ahead of do_ws, in the 'ws' priority group.

Learned timing (3.2): every skillchain seen on the mob we fight gives one sample - the time from the weapon skill that
opened it landing to the skillchain message (weapon skill openers only: a nuke between weapon skills would muddle it).
Kept: the running average, how many, and the two longest (a skillchain that still formed at 9 s proves the window lasts
at least that long). Our own weapon skills also teach the lag from /ws to it landing. From that:
  window   = 8 s until 5 chains were seen, then the 2nd longest seen, never under 8 or over 10 (the game's window)
  delay    = the rule's delay, never under 2 s, never so late the weapon skill lands after the window (window - lag),
             and never over 8 s
  sc.steps = with scf.tune_sc on (default off), the same latest time also caps sc.window_max, sc.window_min is never
             under 2 s and window_max never over 10 s. With tune_sc off, sc.window_min / window_max are used as set.
Learning only runs while scf.on or scf.tune_sc is on (nobody pays for a feature that is off). Saved in scf.learned
when not engaged (at most once a minute) or on zoning - never mid-fight (a save rewrites the shared settings file).

Several characters, one trigger: when a follow-up is queued, the character tells the others (IPC 'vg_scf <mob> <name>
<due>'); a character holding a follow-up for the same mob due within 1.5 s of that one drops its own unless its name
comes first alphabetically - so 'anyone' rules set on all three (//vg all scf add ...) give one weapon skill, not three.

Team planner (Vanguard Control 2.0.0, vg_plan, off by default in the app): each queued follow-up gets a number and is
reported to the app, which answers per follow-up "you close" / "someone else does" (in reach first, then 1000+ TP, most
TP, name). While a plan is fresh (under 3 s old) that answer replaces the alphabetical tie-break; with no fresh plan, or
no answer by the time the weapon skill is due, the alphabetical rule above decides as before.

Aftermath (ws.am) wins over a follow-up: while do_ws wants TP for Aftermath (h.am_need), a follow-up is not queued
and does not hold the TP, unless the follow-up's weapon skill is the Aftermath weapon skill and TP is already enough.
]]
local util = require('vg_util')
local res = require('resources')

local scf = {}
local S, state, h

local MAX_RULES = 4
local MIN_DELAY, MAX_DELAY = 2, 8           -- seconds after the trigger
local WIN_DEFAULT, WIN_HARD = 8, 10         -- the game's skillchain window: assumed / longest it can be
local MISSED = 188

local PROPS = {}
for _, n in pairs(util.skillchain_by_msg) do PROPS[n:lower()] = n end

local function now() return os.clock() end
local function planner() return require('vg_plan') end   -- team planner answers (Vanguard Control 2.0.0)
-- A queued follow-up is gone (used, dropped, expired, Aftermath, rules changed): forget it and tell the app's team
-- planner at once, so it never keeps choosing a follow-up that no longer exists (nothing is sent while it's off).
local function drop_pending(player)
    local p = state.scf and state.scf.pending
    if not p then return end
    state.scf.pending = nil
    player = player or windower.ffxi.get_player()
    if p.pid and player then planner().report_scf(player, p.mob, p.pid, -1) end
end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function job() local p = windower.ffxi.get_player() return p and p.main_job end
local am_blocks

------------------------------------------------------------------------
-- Rules
------------------------------------------------------------------------
-- what a trigger text is: a skillchain property, a weapon skill or a spell (nil = not known)
function scf.trigger_kind(text)
    local s = util.trim(tostring(text or ''))
    if PROPS[s:lower()] then return 'property', PROPS[s:lower()] end
    local w = util.wskill(s)
    if w then return 'ws', w.en end
    local sp = util.spell(s)
    if sp then return 'spell', sp.en end
    return nil
end

local function parse(entry)
    local who, trig, ws, delay = tostring(entry):match('^(.-)|(.-)|(.-)|(.-)$')
    if not who then return nil end
    local kind, tname = scf.trigger_kind(trig)
    local w = util.wskill(util.trim(ws))
    if not kind or not w then return nil end
    who = util.trim(who)
    if who == '' then who = 'anyone' end
    return { who = who:lower(), who_name = who, kind = kind, trigger = tname, ws = w.en, delay = tonumber(delay) or 3 }
end

function scf.rules()
    local out = {}
    for _, e in ipairs(util.split(tostring(util.job_get(S.scf_rules, job()) or ''), ';')) do
        local r = parse(e)
        if r and #out < MAX_RULES then out[#out + 1] = r end
    end
    return out
end

local function store_rules(list)
    local parts = {}
    for _, r in ipairs(list) do
        parts[#parts + 1] = ('%s|%s|%s|%s'):format(r.who_name, r.trigger, r.ws, tostring(r.delay))
    end
    S.scf_rules = S.scf_rules or {}
    util.job_set(S.scf_rules, job(), table.concat(parts, ';'))
end

-- "who|trigger|ws|delay" -> true, the rule | false, why
function scf.add(text)
    local r = parse(text)
    if not r then
        return false, 'use //vg scf add <name or anyone>|<weapon skill, spell or skillchain>|<my weapon skill>|<seconds>'
    end
    local list = scf.rules()
    if #list >= MAX_RULES then return false, ('already %d rules (//vg scf clear first)'):format(MAX_RULES) end
    list[#list + 1] = r
    store_rules(list)
    return true, r
end

-- The app's rule rows (Vanguard Control 2.0.0, Skillchains tab): put rule n in place ("who|trigger|ws|delay"); n past the
-- last rule adds it at the end. true, the rule | false, why. (//vg scf set <n> <who>|<trigger>|<ws>|<delay>)
function scf.set(n, text)
    n = tonumber(n)
    if not n or n < 1 or n > MAX_RULES or n ~= math.floor(n) then return false, ('rule number 1 to %d'):format(MAX_RULES) end
    local r = parse(text)
    if not r then
        return false, 'use //vg scf set <1-4> <name or anyone>|<weapon skill, spell or skillchain>|<my weapon skill>|<seconds>'
    end
    local list = scf.rules()
    if n > #list then list[#list + 1] = r else list[n] = r end
    store_rules(list)
    drop_pending()
    state.scf = nil
    return true, r
end

-- What the app shows (vg_menu.extra): the switches, the rules and the learned timing.
function scf.info()
    local out = { on = (S.scf and S.scf.on == true) or false, tune_sc = (S.scf and S.scf.tune_sc == true) or false, rules = {} }
    for _, r in ipairs(scf.rules()) do
        out.rules[#out.rules + 1] = { who = r.who_name, kind = r.kind, trigger = r.trigger, ws = r.ws, delay = r.delay,
                                      real = scf.sane_delay(r.delay) }
    end
    local l = scf.learned()
    out.learned = { n = l.n, avg = l.avg, window = l.window, lag = l.lag, max_delay = l.max_delay }
    return out
end

function scf.clear(n)
    n = tonumber(n)
    local list, out = scf.rules(), {}
    for i, r in ipairs(list) do if n and i ~= n then out[#out + 1] = r end end
    store_rules(out)
    drop_pending()
    state.scf = nil
end

function scf.describe(r)
    local what = r.kind == 'property' and (r.trigger .. ' (skillchain)') or r.trigger
    return ('when %s makes %s, use %s after %ss (really %.1fs)'):format(r.who_name, what, r.ws, tostring(r.delay),
        scf.sane_delay(r.delay))
end

------------------------------------------------------------------------
-- Learned timing (3.2)
------------------------------------------------------------------------
local L = { avg = 0, n = 0, top = 0, top2 = 0, lag = 1.0, lag_n = 0 }
local loaded_from

local function load_learned()
    local txt = tostring(S.scf and S.scf.learned or '')
    if loaded_from == txt then return end
    loaded_from = txt
    L = { avg = 0, n = 0, top = 0, top2 = 0, lag = 1.0, lag_n = 0 }
    for k, v in txt:gmatch('([%w_]+)=([%d%.]+)') do
        if L[k] ~= nil then L[k] = tonumber(v) or L[k] end
    end
end

local function learned_text()
    return ('avg=%.2f n=%d top=%.2f top2=%.2f lag=%.2f lag_n=%d'):format(L.avg, L.n, L.top, L.top2, L.lag, L.lag_n)
end

local function dirty()
    S.scf.learned = learned_text()
    loaded_from = S.scf.learned
    state.scf_learn_dirty = true
end

function scf.learn_window(secs)
    load_learned()
    if not secs or secs < 0.5 or secs > WIN_HARD + 2 then return false end   -- not one chain (or a stale opener)
    L.n = L.n + 1
    L.avg = L.n == 1 and secs or (L.avg * 0.7 + secs * 0.3)
    if secs > L.top then L.top, L.top2 = secs, L.top elseif secs > L.top2 then L.top2 = secs end
    dirty()
    return true
end

function scf.learn_lag(secs)
    load_learned()
    if not secs or secs < 0 or secs > 5 then return false end
    L.lag_n = L.lag_n + 1
    L.lag = L.lag_n == 1 and secs or (L.lag * 0.7 + secs * 0.3)
    dirty()
    return true
end

-- How long after an opener a skillchain can still form
function scf.window()
    load_learned()
    if L.n >= 5 then return clamp(math.min(L.top2, WIN_HARD), WIN_DEFAULT, WIN_HARD) end
    return WIN_DEFAULT
end

-- the latest a weapon skill may be SENT after the opener and still land inside the window
local function latest() return scf.window() - clamp(L.lag, 0, 3) end

function scf.max_delay() return clamp(latest(), MIN_DELAY, MAX_DELAY) end
function scf.sane_delay(d) return clamp(tonumber(d) or 3, MIN_DELAY, scf.max_delay()) end

-- sc.steps' window. scf.tune_sc off (default): exactly as set (sc.window_min / window_max, as before 1.2.0).
-- tune_sc on: kept sane - never under 2 s / over 10 s, and not past the learned latest time.
function scf.sc_window()
    if not (S.scf and S.scf.tune_sc) then
        return tonumber(S.sc.window_min) or 3, tonumber(S.sc.window_max) or WIN_DEFAULT
    end
    local lo = math.max(MIN_DELAY, tonumber(S.sc.window_min) or 3)
    local hi = math.min(WIN_HARD, tonumber(S.sc.window_max) or WIN_DEFAULT)
    hi = math.min(hi, latest())
    if hi < MIN_DELAY + 1 then hi = MIN_DELAY + 1 end
    if lo >= hi then lo = math.max(MIN_DELAY, hi - 1) end
    return lo, hi
end

function scf.learned()
    load_learned()
    return { avg = L.avg, n = L.n, window = scf.window(), lag = L.lag, max_delay = scf.max_delay() }
end

------------------------------------------------------------------------
-- Watching the fight
------------------------------------------------------------------------
local function on() return S.scf and S.scf.on == true end
local function learning() return S.scf and (S.scf.on == true or S.scf.tune_sc == true) end

local function our_mob_id()
    local bt = windower.ffxi.get_mob_by_target('bt')
    local t = windower.ffxi.get_mob_by_target('t')
    local m = bt or t
    return m and m.id
end

local function listed(player)
    return h.in_sc_steps and h.in_sc_steps(player) or false
end

local function who_ok(r, actor, me)
    if r.who == 'anyone' then return actor.id ~= me.id end      -- (not my own: one owner, no chasing myself)
    return actor.name and actor.name:lower() == r.who
end

-- Aftermath upkeep (ws.am, do_ws) needs the TP and this follow-up would not give it Aftermath
am_blocks = function(player, ws_name)
    if not h.am_need then return false end
    local am, am_ws = h.am_need(player)
    if not am then return false end
    return not (am_ws and ws_name and am_ws:lower() == ws_name:lower() and (player.vitals.tp or 0) >= am * 1000)
end

-- called for every action packet (Vanguard.lua 'action' handler)
function scf.on_action(act, player)
    if not player or not act then return end
    local first = act.targets and act.targets[1]
    local a1 = first and first.actions and first.actions[1]
    if not first or not a1 then return end
    local cat = act.category
    if cat ~= 3 and cat ~= 4 then return end
    local wsr = cat == 3 and res.weapon_skills[act.param]
    local spr = cat == 4 and res.spells[act.param]
    if not wsr and not spr then return end
    if cat == 3 and a1.message == MISSED then return end
    local t = now()
    if not learning() then return end                       -- (scf and tune_sc both off: nothing to learn or follow)

    -- my own weapon skill landing: how long /ws takes (3.2)
    if act.actor_id == player.id and wsr then
        local sent = state.attempts and state.attempts['ws:' .. wsr.en]
        if sent and t - sent <= 5 then scf.learn_lag(t - sent) end
    end

    local mob = our_mob_id()
    if not mob or first.id ~= mob then return end
    state.scf = state.scf or { open = {}, pending = nil }
    local st = state.scf
    local prop = a1.has_add_effect and util.skillchain_by_msg[a1.add_effect_message]

    -- learned window (3.2): opener weapon skill -> skillchain
    if prop and wsr then
        local o = st.open[mob]
        if o then scf.learn_window(t - o) end
    end
    if wsr then st.open[mob] = t
    elseif prop then st.open[mob] = nil end                 -- a spell made it: the next sample would be muddled

    if not on() or listed(player) then return end
    local actor = windower.ffxi.get_mob_by_id(act.actor_id)
    if not actor or (actor.is_npc and actor.spawn_type == 16) then return end   -- (a monster's own move)
    for i, r in ipairs(scf.rules()) do
        local hit = (r.kind == 'property' and prop and prop:lower() == r.trigger:lower())
            or (r.kind == 'ws' and wsr and wsr.en:lower() == r.trigger:lower())
            or (r.kind == 'spell' and spr and spr.en:lower() == r.trigger:lower())
        if hit and who_ok(r, actor, player) then
            -- Aftermath upkeep wants this TP (ws.am): it wins, no follow-up (see the top of this file)
            if am_blocks(player, r.ws) then return end
            local d = scf.sane_delay(r.delay)
            state.scf_pid = (state.scf_pid or 0) % 100000 + 1
            st.pending = { mob = mob, ws = r.ws, rule = i, at = t, due = t + d, expires = t + scf.max_delay() + 1,
                           pid = state.scf_pid, peers = {},
                           why = ('%s %s'):format(actor.name or '?', r.kind == 'property' and (prop .. ' skillchain') or r.trigger) }
            -- tell the other characters: one follow-up per trigger across the team
            if windower.send_ipc_message then
                windower.send_ipc_message(('vg_scf %d %s %.1f'):format(mob, player.name, d))
            end
            -- and the app's team planner, when it is on (vg_plan: nothing is sent while it's off)
            local w, m = util.wskill(r.ws), windower.ffxi.get_mob_by_id(mob)
            local reach = (w and w.range == 12) and 21.99 or (tonumber(S.ws.max_range) or 6)
            planner().report_scf(player, mob, state.scf_pid, d, player.vitals and player.vitals.tp or 0,
                m and util.dist(m) <= reach)
            return                                           -- one trigger, one follow-up (the first rule that fits)
        end
    end
end

-- Another character queued a follow-up for this mob, due in <secs>: the alphabetically first name keeps its one.
-- Team planner on (a fresh plan from the app, vg_plan): the app picks who closes; the other character is only noted
-- here, and if the app gives no answer by the time the weapon skill is due, the alphabetical rule still decides then.
function scf.on_ipc(player, mob_id, from, secs)
    local p = state.scf and state.scf.pending
    if not p or not player or p.mob ~= tonumber(mob_id) then return end
    local due = now() + (tonumber(secs) or 0)
    if math.abs(due - p.due) > 1.5 then return end           -- (a later step of a planned chain: keep mine)
    if tostring(from):lower() < tostring(player.name):lower() then
        if planner().fresh() then
            p.peers = p.peers or {}
            p.peers[#p.peers + 1] = tostring(from)
            return
        end
        drop_pending(player)
        if h.log then h.log(('Skillchain follow: %s takes this one (%s)'):format(from, p.why)) end
    end
end

-- The team planner's answer for my follow-up: 'drop' (someone else closes) clears it. Without an answer, a character
-- noted by on_ipc while the plan was fresh still wins by name (the old rule). true = my follow-up is gone.
local function plan_drops(player, p, final)
    local v = planner().scf_verdict(player, p.pid)
    local who
    if v == 'drop' then who = 'the team planner'
    elseif v == nil and final and p.peers and #p.peers > 0 then who = p.peers[1] end
    if not who then return false end
    drop_pending(player)
    if h.log then h.log(('Skillchain follow: %s takes this one (%s)'):format(who == 'the team planner' and 'another character (team planner)' or who, p.why)) end
    return true
end

local function pending_for(t)
    local p = state.scf and state.scf.pending
    if not p then return nil end
    if now() > p.expires or not t or t.id ~= p.mob or (t.hpp or 0) <= 0 then
        drop_pending()
        return nil
    end
    return p
end

-- A follow-up waits for its moment on this mob: no one else spends the TP (do_ws holds)
function scf.owns_tp(player, t)
    if not player or not on() or listed(player) then return false end
    local p = pending_for(t)
    if not p then return false end
    if am_blocks(player, p.ws) then drop_pending(player) return false end   -- (Aftermath wins)
    if plan_drops(player, p, false) then return false end   -- (the team planner gave it to someone else)
    return true
end

local function save_learned(force)
    if not state.scf_learn_dirty or not h.save then return end
    if not force and h.recently('scf_learn_save', 60) then return end
    h.mark('scf_learn_save')
    state.scf_learn_dirty = nil
    h.save()
end

-- the 'ws' group, right after do_skillchain: the pending follow-up when its delay has passed
function scf.tick(player)
    if player.status ~= 1 then save_learned() end           -- (never mid-fight: the save rewrites settings.xml)
    if not on() or player.status ~= 1 or (h.amnesia and h.amnesia(player)) or listed(player) then return false end
    local t = windower.ffxi.get_mob_by_target('t')
    local p = pending_for(t)
    if not p then return false end
    if plan_drops(player, p, false) then return false end
    if now() < p.due then return false end
    if plan_drops(player, p, true) then return false end    -- (no answer from the planner: the old rule, by name)
    if am_blocks(player, p.ws) then drop_pending(player) return false end   -- (Aftermath wins: do_ws next)
    if player.vitals.tp < 1000 then return false end        -- (still ours until its window runs out)
    local w = util.wskill(p.ws)
    if not w or not util.ws_fits(w.en) then
        drop_pending(player)
        return false
    end
    local reach = (w.range == 12) and 21.99 or (tonumber(S.ws.max_range) or 6)
    if util.dist(t) > reach then return false end
    drop_pending(player)                                     -- used once, sent or not (and the app is told)
    if h.log then h.log(('Skillchain follow: %s after %s'):format(w.en, p.why)) end
    return h.use_ws(w.en, 'scf') and true or false
end

function scf.on_zone()
    drop_pending()
    state.scf = nil
    save_learned(true)
end

function scf.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers or {}
    S.scf = S.scf or { on = false, tune_sc = false, learned = '' }
    S.scf_rules = S.scf_rules or {}
end

return scf
