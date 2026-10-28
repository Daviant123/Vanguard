--[[
Vanguard: finishing weapon skill (his request 2026-10-16: "I need to kill the monster with Atonement, there is no way
in Vanguard to guarantee that can happen"). EasyFarm lets a weapon skill fire by the mob's HP; this goes further, for
trials that need the killing blow to be a set weapon skill, with several characters hitting the same mob:

  ws.finish        the weapon skill that should land the kill ('' = off)
  ws.finish_at     use it once the mob's HP is at or under this % (and TP is 1000+); 0 = Auto: learn how much of each
                   kind of mob one hit takes (HP % just before and 1.5 s after it lands) and use it once the mob is
                   low enough for one hit to kill it (his report 2026-10-17: "it uses atonement so early the mob
                   doesnt get killed by atonement"). Auto always saves TP for it.
  ws.finish_save   save TP for it: the normal weapon skill isn't used while a finisher is set
  ws.finish_others the other characters stop attacking that mob once it's that low (they keep curing / buffing)
  ws.finish_wait   if the mob gets that low before TP is ready, stop attacking until TP is 1000 (a tank still gains
                   TP from being hit), then attack again and finish it - only from 700 TP up, and 10 s at most

Normal game commands only (/ws, /attackoff, /attack). The "stop attacking" order to the others goes over Windower IPC
on this PC (vg_finish <mob id> <name>).
]]

local finish = {}
local S, state, h

local function clock() return os.clock() end

local function on(name) return name and name ~= '' and name:lower() ~= 'none' end

-- Auto finish point: per kind of mob, the HP % recent hits took (newest last) and the highest HP % a hit has killed at
local learned, killed_at = {}, {}
local adjust = {}             -- kind -> % added to the line from its misses (upgrade 26)
local store_learned          -- (below)

local function auto() return (tonumber(S.ws.finish_at) or 25) <= 0 end

-- Stop attacking to save TP only when TP is nearly there: TP comes from hitting (or from being hit), so stopping at
-- 260 TP left his PLD standing next to the mob doing nothing for 30 s, again and again (his report 2026-10-21: "daviant
-- is doing nothing"). Under this it keeps attacking; the weapon skill goes off if TP gets there in time.
local HOLD_TP = 700

-- The mob's HP % at which the finishing weapon skill should go off.
function finish.line(t)
    if not auto() then return tonumber(S.ws.finish_at) or 25 end
    local l = learned[t.name]
    if l and #l > 0 then
        -- the typical recent hit (the middle one), less a tenth (others keep hitting while it goes off), never under
        -- 3 %. Not the weakest: Atonement's damage follows the hate we hold, so one early weak hit (fired at 30 %
        -- right after a reload) set the line to 3 % - his live run, 2026-10-17: the kill landed on 3 of 23 Peapuks,
        -- normal hits finishing them first
        local sorted = {}
        for i, v in ipairs(l) do sorted[i] = v end
        table.sort(sorted)
        local mid = sorted[math.floor((#sorted + 1) / 2)]
        local line = math.max(3, math.floor(mid * 0.9))
        -- a hit that killed from higher up shows it can be trusted that far
        if killed_at[t.name] and killed_at[t.name] > line and killed_at[t.name] <= mid then line = killed_at[t.name] end
        -- tuned by its misses, between 3 % and the strongest recent hit (upgrade 30: capped at the typical hit it
        -- couldn't rise far enough - his Buzzfly run: 24 died first, 3 didn't-kill)
        -- (upgrade 33: also a hit that killed from higher up, +2 - his Buzzflies measured 12-13 % but one Atonement
        -- killed from 15 %, and the misses were still mostly mobs dying first with the line stuck at 13 %; going a bit
        -- too high shows up as "didn't kill" and comes back down)
        local top = math.max(sorted[#sorted], killed_at[t.name] or 0) + 2
        return math.max(3, math.min(top, line + (adjust[t.name] or 0)))
    end
    return killed_at[t.name] or 30                    -- nothing learned yet: a careful first guess, learned from
end

-- Waiting for TP (finish_wait, or always while helping with a Magian trial): with Auto, stop attacking a little above
-- the finish line - by the time the mob is under it, a couple of normal hits kill it before TP is 1000 (his real run,
-- 2026-10-17: Atonement landed 42 of 66 Peapuk kills, the line being 9 %).
-- (also whenever the mob is one an open weapon skill trial for this weapon skill wants - upgrade 29: his next trial
-- (Buzzflies) wasn't on "Help finish it", so the hold-off never ran and 11 of 12 misses were mobs dying first)
local function waits(t)
    local okt, trm = pcall(require, 'vg_trials')
    if S.ws.finish_wait or (okt and trm.assisting and trm.assisting()) then return true end
    local ok, tr = pcall(require, 'vg_trials')
    return ok and tr.wants and t and t.name and tr.wants(t.name, S.ws.finish) or false
end

function finish.wait_line(t)
    local line = finish.line(t)
    if not waits(t) then return line end
    -- (a % he picks too, not only Auto) - 5 to 10 % above the line: line + line held off from 60 % on a kind of mob
    -- not learned yet (the 30 % first guess), found by the fuzz test
    return line + math.min(10, math.max(5, line))
end

-- Our weapon skill hit something (from the 'action' event): if it's the finisher, measure what it does.
function finish.note_ws(target_id, ws_name)
    if not on(S.ws.finish) or not ws_name or ws_name:lower() ~= S.ws.finish:lower() then return end
    local m = windower.ffxi.get_mob_by_id(target_id)
    if not m or not m.name then return end
    local seen = state.finish_seen and state.finish_seen.id == target_id and state.finish_seen.hpp or 0
    local before = math.max(seen, m.hpp or 0)
    if before <= 0 then return end
    state.finish_probe = { id = target_id, name = m.name, before = before, t = clock() }
    state.finish_last_ws = { id = target_id, before = before }
end

function finish.learn_tick()
    local p = state.finish_probe
    if not p or clock() - p.t < 1.5 then return end
    state.finish_probe = nil
    local m = windower.ffxi.get_mob_by_id(p.id)
    if not m or (m.hpp or 0) <= 0 or m.valid_target == false or m.status == 2 or m.status == 3 then
        local was = killed_at[p.name]
        killed_at[p.name] = math.max(killed_at[p.name] or 0, p.before)      -- it killed: one hit is at least that much
        if killed_at[p.name] ~= was then store_learned() end
        return
    end
    local drop = p.before - m.hpp
    if drop <= 0 then return end
    local l = learned[p.name] or {}
    l[#l + 1] = drop
    while #l > 5 do table.remove(l, 1) end
    learned[p.name] = l
    store_learned()
    if auto() then h.log(('%s took %d%% of %s: it will finish them from %d%% HP'):format(S.ws.finish, drop, p.name, finish.line(m))) end
end

-- For the app: what Auto has learned
function finish.learned_list()
    local out = {}
    for name in pairs(learned) do out[#out + 1] = { n = name, at = finish.line({ name = name }) } end
    for name, v in pairs(killed_at) do if not learned[name] then out[#out + 1] = { n = name, at = finish.line({ name = name }) } end end
    table.sort(out, function(a, b) return a.n < b.n end)
    return out
end

-- On the finisher, from do_ws. Returns 'used' (weapon skill sent), 'block' (no normal weapon skill now) or nil.
function finish.ws(player, t)
    local f = S.ws.finish
    if not on(f) or not t or not t.hpp or t.hpp <= 0 then return nil end
    -- only while a Magian trial needs this mob killed with it (upgrade 38): with no trial left he was still holding TP
    -- for Atonement on every Bog Body, at half the kills an hour; otherwise the normal weapon skill rules apply
    if S.ws.finish_trial_only then
        local ok, tr = pcall(require, 'vg_trials')
        if not (ok and ((tr.assisting and tr.assisting()) or (tr.wants and tr.wants(t.name, f)))) then return nil end
    end
    finish.learn_tick()
    state.finish_seen = { id = t.id, hpp = t.hpp }
    local line = finish.line(t)
    if t.hpp > line and t.hpp <= finish.wait_line(t) and player.vitals.tp < 1000 and player.vitals.tp >= HOLD_TP then
        -- close to the line without TP: stop now (the others too), attack again when TP is 1000
        if S.ws.finish_others and state.finish_told ~= t.id then
            state.finish_told = t.id
            windower.send_ipc_message(('vg_finish %d %s'):format(t.id, player.name))
        end
        if player.status == 1 and state.finish_wait ~= t.id and not state.ef_gap then   -- (EasyFarm's engine re-engages: no hold)
            state.finish_wait, state.finish_wait_t = t.id, clock()
            windower.send_command('input /attackoff')
            h.log(('%s is at %d%% and TP is %d: holding off until TP is 1000, then %s at %d%%'):format(t.name, t.hpp,
                player.vitals.tp, f, line))
            state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
        end
        return 'block'
    end
    if t.hpp <= line then
        if S.ws.finish_others and state.finish_told ~= t.id then
            state.finish_told = t.id
            windower.send_ipc_message(('vg_finish %d %s'):format(t.id, player.name))
            h.log(('%s is at %d%%: the others stop attacking, %s finishes it with %s'):format(t.name, t.hpp, player.name, f))
        end
        if player.vitals.tp >= 1000 then
            if h.ws_in_range(t, true) and not h.recently('ws:' .. f, 3) then return h.use_ws(f) and 'used' end
            return 'block'
        end
        if waits(t) and player.vitals.tp >= HOLD_TP and player.status == 1 and state.finish_wait ~= t.id and not state.ef_gap then
            state.finish_wait, state.finish_wait_t = t.id, clock()
            windower.send_command('input /attackoff')
            h.log(('%s is low and TP is %d: stopping until TP is 1000, then %s'):format(t.name, player.vitals.tp, f))
            state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
        end
        return 'block'
    end
    if S.ws.finish_save or auto() then return 'block' end
    return nil
end

-- Waiting for TP after stopping (finish_wait): attack again when TP is ready. True while it's waiting (so farming /
-- assist don't re-engage early); acts once TP is there.
function finish.waiting(player)
    local id = state.finish_wait
    if not id then return false end
    local bt = windower.ffxi.get_mob_by_target('bt')
    if not bt or bt.id ~= id or (bt.hpp or 0) <= 0 then state.finish_wait = nil return false end
    if player.status == 1 then return false end
    -- TP isn't coming (the mob isn't hitting us): don't stand there - attack again after 10 s
    if player.vitals.tp >= 1000 or clock() - (state.finish_wait_t or clock()) > 10 then
        if not h.recently('finish:attack', 3) then
            h.mark('finish:attack')
            windower.send_command('input /attack <bt>')
            h.log('TP ready: attacking ' .. bt.name .. ' again to finish it')
            state.busy_until = math.max(state.busy_until or 0, clock() + 1.5)
        end
        return true
    end
    return true
end

-- On the others: the finisher said "leave this one to me".
function finish.on_ipc(mob_id, from)
    state.finish_hold = { id = tonumber(mob_id), from = from, t = clock() }
end

-- On the others, every tick: true while holding off a mob that's being finished (only curing / buffing then).
function finish.held(player)
    finish.learn_tick()
    local hold = state.finish_hold
    if not hold then return false end
    local m = windower.ffxi.get_mob_by_id(hold.id)
    if not m or (m.hpp or 0) <= 0 or clock() - hold.t > 120 then state.finish_hold = nil return false end
    local t = windower.ffxi.get_mob_by_target('t')
    local bt = windower.ffxi.get_mob_by_target('bt')
    local mine = (t and t.id == hold.id) or (bt and bt.id == hold.id)
    if not mine and player.status ~= 1 then return true end    -- idle: don't assist onto it either
    if player.status == 1 and t and t.id == hold.id and not h.recently('finish:off', 3) then
        h.mark('finish:off')
        windower.send_command('input /attackoff')
        h.log(('Leaving %s to %s (finishing weapon skill)'):format(m.name or 'it', hold.from))
    end
    return mine or player.status ~= 1
end

-- What Auto learned is kept in the settings (ws.learned = "Peapuk=10/11/9@9;..."), so a reload or an update doesn't
-- start again from the 30 % guess
-- Auto tunes itself from the trial's misses (upgrade 26; his run: 8 of 9 misses were Peapuks dying in one go from
-- above the line): died from above the line -> 2 % higher; went off but didn't kill -> 2 % lower.
function finish.note_miss(name, why, mob_id)
    if not auto() or not name or not learned[name] then return end
    local step = (why == 'jumped' and 2) or (why == 'ws_no_kill' and -2) or 0
    if step == 0 then return end
    local before = finish.line({ name = name })
    -- "didn't kill" only says the line is too high when it went off at the line (not a 30 % first guess, not a
    -- weapon skill used higher up some other way)
    if why == 'ws_no_kill' then
        local w = state.finish_last_ws
        if not (w and w.id == mob_id and w.before <= before + 1) then return end
    end
    adjust[name] = math.max(-20, math.min(20, (adjust[name] or 0) + step))
    local after = finish.line({ name = name })
    if after ~= before then
        h.log(('%s: %s - %s from %d%% now'):format(name, why == 'jumped' and 'it died before the weapon skill'
            or "the weapon skill didn't kill it", S.ws.finish, after))
        store_learned()
    else
        adjust[name] = adjust[name] - step                          -- at the limit: don't build up
    end
end

store_learned = function()
    local parts = {}
    for name, l in pairs(learned) do
        local nums = {}
        for i, v in ipairs(l) do nums[i] = tostring(v) end
        local a = adjust[name] or 0
        parts[#parts + 1] = name .. '=' .. table.concat(nums, '/') .. (killed_at[name] and ('@' .. killed_at[name]) or '')
            .. (a > 0 and ('+' .. a) or a < 0 and tostring(a) or '')
    end
    for name, v in pairs(killed_at) do if not learned[name] then parts[#parts + 1] = name .. '=@' .. v end end
    table.sort(parts)
    S.ws.learned = table.concat(parts, ';')
    if h and h.save then pcall(h.save) end
end
finish.store_learned = store_learned

local function load_learned()
    learned, killed_at, adjust = {}, {}, {}
    for entry in tostring(S.ws.learned or ''):gmatch('[^;]+') do
        local name, nums, k, a = entry:match('^(.-)=([%d/]*)@?(%d*)([+-]?%d*)$')
        if name and name ~= '' then
            if a ~= '' and tonumber(a) then adjust[name] = tonumber(a) end
            local l = {}
            for v in nums:gmatch('%d+') do l[#l + 1] = tonumber(v) end
            if #l > 0 then learned[name] = l end
            if k ~= '' then killed_at[name] = tonumber(k) end
        end
    end
end

function finish.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
    load_learned()
end

return finish
