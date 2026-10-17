--[[
Vanguard: Magian Trials helper (his request 2026-10-16: "build in magian trials tracker or a completion assist in the
farming bot").

  Track    trials added by clicking in the app: "defeat N <mobs>" or "defeat N <mobs> with <weapon skill>" (a kill
           counts for a weapon skill trial only when that weapon skill was the killing blow - it hit the mob within the
           last 3 seconds before it died). <mobs> = any, or a mob name (part of it matches).
  Assist   "Help finish it": farming fights the trial's mobs; for a weapon skill trial the finishing weapon skill
           (vg_finish) is set to that weapon skill with TP saved for it and the others told to leave the mob, so every
           kill can count. Farming stops when the trial's count is reached ("Magian trial done").
  Game     the game's own trial messages aren't interpreted (their exact wording isn't known here): the last chat line
           mentioning a Magian trial is shown in the app as it is, so the two counts can be compared.

Settings: trials = { t1 = "kind|goal|ws|mobs|count", ... }, trial_assist = key. Normal game commands only.
]]

local util = require('vg_util')
local res = require('resources')

local trials = {}
local S, state, h

local function now() return os.clock() end

local function decode(v)
    local kind, goal, ws, mobs, count = (v or ''):match('^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$')
    if not kind then return nil end
    return { kind = kind, goal = tonumber(goal) or 0, ws = ws, mobs = mobs, count = tonumber(count) or 0 }
end

local function encode(t) return table.concat({ t.kind, tostring(t.goal), t.ws or '', t.mobs or '', tostring(t.count) }, '|') end

local function keys()
    local out = {}
    for k, v in pairs(S.trials or {}) do if type(v) == 'string' and v ~= '' then out[#out + 1] = k end end
    table.sort(out, function(a, b) return (tonumber(a:sub(2)) or 0) < (tonumber(b:sub(2)) or 0) end)
    return out
end

function trials.list()
    local out = {}
    for _, k in ipairs(keys()) do
        local t = decode(S.trials[k])
        if t then
            local rt = state.trial_rate and state.trial_rate[k]
            out[#out + 1] = { k = k, kind = t.kind, goal = t.goal, ws = t.ws, mobs = t.mobs, count = t.count,
                              hits = rt and rt.hit or nil, tries = rt and rt.all or nil, why = rt and rt.why or nil,
                              assist = S.trial_assist == k or nil, done = t.count >= t.goal and t.goal > 0 or nil }
        end
    end
    return out
end

-- "add kill|100||Apex Bat" or "add ws|50|Savage Blade|"
function trials.add(spec)
    local kind, goal, ws, mobs = (spec or ''):match('^%s*(%a+)%s*|%s*(%d+)%s*|([^|]*)|(.*)$')
    if not kind or (kind ~= 'kill' and kind ~= 'ws') then return nil end
    ws = util.trim(ws or '')
    if kind == 'ws' then
        local w = util.wskill(ws)
        if not w then return nil end
        ws = w.en
    else
        ws = ''
    end
    S.trials = S.trials or {}
    local n = 1
    while S.trials['t' .. n] and S.trials['t' .. n] ~= '' do n = n + 1 end
    S.trials['t' .. n] = encode({ kind = kind, goal = tonumber(goal), ws = ws, mobs = util.trim(mobs or ''), count = 0 })
    return 't' .. n
end

function trials.remove(k)
    if S.trials and S.trials[k] then S.trials[k] = '' end
    if S.trial_assist == k then S.trial_assist = '' end
end

function trials.reset(k)
    local t = S.trials and decode(S.trials[k])
    if t then t.count = 0 S.trials[k] = encode(t) end
end

-- our weapon skill hit a mob (from the 'action' event): remembered for 3 s for "the killing blow"
function trials.note_ws(target_id, ws_name)
    state.trial_ws = state.trial_ws or {}
    state.trial_ws[target_id] = { n = ws_name, t = now() }
end

local function matches(name, pattern)
    if not pattern or pattern == '' then return true end
    return (name or ''):lower():find(pattern:lower(), 1, true) ~= nil
end

-- a party kill (vg_stats): count it for every trial it fits
function trials.on_kill(mob)
    if not mob then return end
    local hit = state.trial_ws and state.trial_ws[mob.id]
    local finisher = hit and now() - hit.t <= 3 and hit.n or nil
    local changed = false
    for _, k in ipairs(keys()) do
        local t = decode(S.trials[k])
        -- how often the weapon skill lands the kill this session (shown in the app)
        if t and t.kind == 'ws' and t.count < t.goal and matches(mob.name, t.mobs) then
            state.trial_rate = state.trial_rate or {}
            local rt = state.trial_rate[k] or { hit = 0, all = 0, why = {} }
            rt.all = rt.all + 1
            if finisher and finisher == t.ws then rt.hit = rt.hit + 1
            else
                -- why it missed (upgrade 25), so the % can be tuned: the weapon skill went off but didn't kill / TP
                -- wasn't ready / it died in one go from above the line / anything else
                local why = 'other'
                local p = windower.ffxi.get_player()
                local okf, fin = pcall(require, 'vg_finish')
                local seen = state.finish_seen and state.finish_seen.id == mob.id and state.finish_seen.hpp
                local line = okf and fin.line and mob.name and fin.line(mob) or nil
                if hit and hit.n == t.ws then why = 'ws_no_kill'
                elseif p and p.vitals and (p.vitals.tp or 0) < 1000 then why = 'no_tp'
                elseif seen and line and seen > line then why = 'jumped' end
                rt.why = rt.why or {}
                rt.why[why] = (rt.why[why] or 0) + 1
                if okf and fin.note_miss and mob.name then fin.note_miss(mob.name, why, mob.id) end
            end
            state.trial_rate[k] = rt
        end
        if t and t.count < t.goal and matches(mob.name, t.mobs) and (t.kind == 'kill' or (finisher and finisher == t.ws)) then
            t.count = t.count + 1
            S.trials[k] = encode(t)
            changed = true
            if t.count >= t.goal then h.log(('Magian trial done: %d / %d%s'):format(t.count, t.goal, t.ws ~= '' and (' with ' .. t.ws) or '')) end
        end
    end
    if state.trial_ws then state.trial_ws[mob.id] = nil end
    if changed then h.save() end
end

-- the game's own trial lines, shown as they are
function trials.on_text(text)
    if text and text:lower():find('magian', 1, true) then
        state.trial_game = text:gsub('[%c]', ' '):sub(1, 160)
    end
end

-- "Help finish it": farming set up for this trial (or off)
function trials.assist(k)
    local t = S.trials and decode(S.trials[k])
    if not t or S.trial_assist == k then S.trial_assist = '' return false end
    S.trial_assist = k
    if t.mobs ~= '' then S.farm.targets, S.farm.mode = t.mobs, 'list' end
    if t.kind == 'ws' then
        S.ws.finish = t.ws
        S.ws.finish_save, S.ws.finish_others = true, true
        if S.ws.finish_at > 0 and S.ws.finish_at < 30 then S.ws.finish_at = 30 end   -- (Auto - 0 - stays Auto)
        S.modules.ws = true
    end
    h.log(('Helping with the trial: %s%s, %d to go'):format(t.mobs ~= '' and t.mobs or 'any mob',
        t.ws ~= '' and (' finished with ' .. t.ws) or '', math.max(0, t.goal - t.count)))
    return true
end

-- for farming's stop conditions: the trial it's helping with is done
function trials.assist_done()
    local k = S.trial_assist
    local t = k and k ~= '' and S.trials and decode(S.trials[k])
    return t and t.goal > 0 and t.count >= t.goal or false
end

function trials.game_line() return state.trial_game end

function trials.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return trials
