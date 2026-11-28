--[[
Vanguard: team planner assignments from Vanguard Control (Control 2.0.0, Silmaril audit item 3.1).

With the app's Team planner on (an app setting, off by default) the app reads every character's state and sends one
line to every character, up to 4 times a second and at least once a second:

  plan <seq> cure=<member>:<healer>,... enf=<char>:<mob id>/<mob id>,<char>:- scf=<char>:<mob>:<pid>:1|0,...

  cure  which healer covers which party member. A healer leaves a member planned for another healer alone - unless he
        is under share.emergency HP % (35): then anyone cures him, as before.
  enf   Enfeebler mode: the mobs this character keeps enfeebled (no two characters on the same mob; '-' = none now).
  scf   reactive skillchains: for each follow-up a character queued, 1 = it closes, 0 = someone else does (replaces the
        alphabetical tie-break of vg_scfollow while a plan is fresh).

Rules (the addon must work fully without the app):
  - a plan is used only while FRESH: received under 3 s ago, and only from the app (127.0.0.1, the app's own port,
    settings.bridge.port). Anything else is ignored.
  - no fresh plan, or nothing in it for this character / member / follow-up: the addon's own logic runs unchanged.
  - while plans arrive (the last one under 10 s ago) the state snapshot carries a small 'plan' part (what the planner
    needs: members in heal range, Enfeebler candidates) and queued follow-ups are reported at once ('scfq').
    With the planner off nothing extra is sent.
Nothing here talks to the game.
]]
local util = require('vg_util')

local plan = {}
local S, state, h

local FRESH, ACTIVE = 3, 10
local cur = { at = nil, seq = 0, cure = nil, enf = nil, scf = nil }

local function now() return os.clock() end

-- the last plan, for tests / the status line
function plan.current() return cur end

function plan.fresh() return cur.at ~= nil and now() - cur.at < FRESH end
function plan.active() return cur.at ~= nil and now() - cur.at < ACTIVE end

local function parse(body)
    local out = { cure = nil, enf = nil, scf = nil }
    for sec in tostring(body or ''):gmatch('%S+') do
        local key, val = sec:match('^(%a+)=(.*)$')
        if key == 'cure' then
            out.cure = {}
            for m, healer in val:gmatch('([^,:]+):([^,:]+)') do out.cure[m:lower()] = healer end
        elseif key == 'enf' then
            out.enf = {}
            for who, ids in val:gmatch('([^,:]+):([^,:]*)') do
                local list, set = {}, {}
                for txt in ids:gmatch('%d+') do
                    local id = tonumber(txt)
                    list[#list + 1] = id
                    set[id] = true
                end
                out.enf[who:lower()] = { list = list, set = set }
            end
        elseif key == 'scf' then
            out.scf = {}
            for who, mob, pid, keep in val:gmatch('([^,:]+):(%d+):(%d+):([01])') do
                out.scf[who:lower() .. '#' .. pid] = { mob = tonumber(mob), keep = keep == '1' }
            end
        end
    end
    return out
end

-- A message on the bridge socket. Returns true when it was a plan line (taken or refused).
-- from_ip / from_port: who sent it; only the app (127.0.0.1 and the bridge port) is listened to.
function plan.on_message(data, from_ip, from_port)
    local seq, body = tostring(data or ''):match('^plan (%d+)%s?(.*)$')
    if not seq then return false end
    local port = S and S.bridge and tonumber(S.bridge.port) or 47000
    if from_ip ~= '127.0.0.1' or tonumber(from_port) ~= port then return true end
    local p = parse(body)
    cur = { at = now(), seq = tonumber(seq), cure = p.cure, enf = p.enf, scf = p.scf }
    return true
end

-- forget the plan (zoning, unload, tests)
function plan.clear() cur = { at = nil, seq = 0 } end

------------------------------------------------------------------------
-- (a) cures
------------------------------------------------------------------------
-- The plan gives this member to another healer and he is not in danger: leave him to them.
function plan.cure_elsewhere(member, player)
    if not member or not member.name or not player or not plan.fresh() or not cur.cure then return false end
    local healer = cur.cure[member.name:lower()]
    if not healer or healer:lower() == player.name:lower() then return false end
    local emergency = tonumber(S and S.share and S.share.emergency) or 35
    if (member.hpp or 100) < emergency then return false end      -- (in danger: anyone cures him)
    -- the planned healer can't see him (his "Unable to see" refusal, 1.3.0 audit 3.1, share.unseen): anyone cures him
    if require('vg_share').unseen_by(healer, member.name) then return false end
    return true
end

-- who covers this member (nil = not planned)
function plan.healer_of(name)
    if not plan.fresh() or not cur.cure or not name then return nil end
    return cur.cure[name:lower()]
end

------------------------------------------------------------------------
-- (b) Enfeebler mobs
------------------------------------------------------------------------
-- nil = no plan for me (decide by myself); else { list = {ids in order}, set = {id = true} } (may be empty)
function plan.enf_for(player)
    if not player or not plan.fresh() or not cur.enf then return nil end
    return cur.enf[player.name:lower()]
end

------------------------------------------------------------------------
-- (c) reactive skillchain follow-ups
------------------------------------------------------------------------
-- 'keep' / 'drop' for my follow-up number pid, nil = no answer (decide by myself)
function plan.scf_verdict(player, pid)
    if not player or not pid or not plan.fresh() or not cur.scf then return nil end
    local v = cur.scf[player.name:lower() .. '#' .. tostring(pid)]
    if not v then return nil end
    return v.keep and 'keep' or 'drop'
end

-- tell the app a follow-up was queued (secs until due, tp, in reach) or is gone (secs = -1)
function plan.report_scf(player, mob, pid, secs, tp, reach)
    if not plan.active() or not player or not h or not h.send then return end
    h.send({ type = 'scfq', name = player.name, mob = mob, pid = pid, d = secs, tp = tp, r = reach and true or false })
end

------------------------------------------------------------------------
-- What the planner needs, added to the state snapshot (only while plans arrive)
------------------------------------------------------------------------
-- Only a character that really acts now says "I heal" / "I enfeeble": Vanguard running (settings.enabled), not away
-- (safety.away), standing or fighting (not resting, dead or in an event), not silenced. Otherwise the app would give
-- it members or mobs it never looks after, and the others would leave them alone (review 2026-11-27).
local function acting(player)
    if not S.enabled or (state and state.away) then return false end
    if player.status ~= 0 and player.status ~= 1 then return false end
    if h and h.silenced and h.silenced(player) then return false end
    return true
end
plan.acting = acting

function plan.snap(player)
    if not plan.active() or not player or not S then return nil end
    local out = {}
    if not acting(player) then return nil end
    if S.modules and S.modules.heal and h and h.party_members then
        local list = {}
        -- (members on my heal.ignore list are never cured by me: not offered, so the app gives them to another healer)
        local ignore = {}
        for _, n in ipairs(util.split(S.heal and S.heal.ignore or '', ',')) do ignore[util.trim(n):lower()] = true end
        for _, m in ipairs(h.party_members(tonumber(S.heal and S.heal.range) or 20)) do
            if m.name and m.mob and not ignore[m.name:lower()] then
                list[#list + 1] = { n = m.name, d = math.floor(util.dist(m.mob) * 10 + 0.5) / 10, hpp = m.hpp or 0 }
            end
        end
        out.heal = { casting = h.casting and h.casting() or false, m = list }
    end
    if S.enfeebler and S.enfeebler.on and h and h.enf_candidates then
        local ok, cands = pcall(h.enf_candidates, player)
        local mobs = {}
        for _, c in ipairs(ok and cands or {}) do
            if #mobs >= 12 then break end
            mobs[#mobs + 1] = { id = c.mob.id, d = math.floor(util.dist(c.mob) * 10 + 0.5) / 10, bt = c.bt or nil,
                                 p = c.pull or nil }   -- (p: an unclaimed mob, a pull: only to fill the count)
        end
        out.enf = { n = math.max(1, math.floor(tonumber(S.enfeebler.count) or 1)), mobs = mobs }
    end
    return next(out) and out or nil
end

function plan.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers or {}
end

return plan
