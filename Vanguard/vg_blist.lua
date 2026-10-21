--[[
Vanguard: EasyFarm-style battle lists for farming (his request 2026-10-21: "i want the farming section to look exactly
like easy farm with all its features"). Seven lists, as EasyFarm has them - each a list of actions (abilities, magic,
weapon skills, items) with EasyFarm's conditions:
  start        when a fight with a new mob begins (each action once per mob)
  trusts       trusts called while out of a fight until the party has trust_size members
  pull         how to pull (replaces the single "Pull with" when it has actions)
  battle       during the fight, the first action whose conditions hold
  finish       after the mob dies (EasyFarm's "End"; each once per mob)
  healing      out of a fight, on yourself (cures, items, Sublimation...)
  ws           weapon skills (replace the normal weapon skill while farming when it has actions)
Conditions per action (EasyFarm's names): enabled, Distance (max yalms to the mob), Recast (its own seconds between
uses), your HP % low-high, the target's HP % low-high, MP % reserve low-high, TP low-high, a status effect that must be
there (or must not), only on a mob called ..., and a usage limit per mob. A global cooldown (farm.gcd, ms) between any
two actions. Only normal game commands (/ja /ma /ws /item /ra); nothing read from memory.
Saved per job: settings.blists["<job>_<list>"] = "n=Cure IV;on=1;d=20;..." actions joined by "~".
]]
local util = require('vg_util')
local res = require('resources')

local blist = {}
local S, state, h

local function clock() return os.clock() end

blist.LISTS = { 'start', 'trusts', 'pull', 'battle', 'finish', 'healing', 'ws' }
-- fields: name and defaults (EasyFarm's defaults: everything open, distance 3 for melee-range things)
local FIELDS = { { 'n', '' }, { 'on', 1 }, { 'd', 20 }, { 'rc', 0 }, { 'pl', 0 }, { 'ph', 100 }, { 'tl', 0 }, { 'th', 100 },
                 { 'ml', 0 }, { 'mh', 100 }, { 'tpl', 0 }, { 'tph', 3000 }, { 'st', '' }, { 'sp', 0 }, { 'tn', '' }, { 'lim', 0 } }
blist.FIELDS = FIELDS

local function job() local p = windower.ffxi.get_player() return p and p.main_job end
local function key(list) return (job() or 'NON') .. '_' .. list end

local function decode_action(str)
    local a = {}
    for _, f in ipairs(FIELDS) do a[f[1]] = f[2] end
    for part in tostring(str):gmatch('[^;]+') do
        local k, v = part:match('^(%w+)=(.*)$')
        if k then a[k] = (type(a[k]) == 'number' and tonumber(v)) or v end
    end
    return a
end
local function encode_action(a)
    local out = {}
    for _, f in ipairs(FIELDS) do
        local v = a[f[1]]
        if v ~= nil and v ~= f[2] or f[1] == 'n' then out[#out + 1] = f[1] .. '=' .. tostring(v):gsub('[;~=]', '') end
    end
    return table.concat(out, ';')
end

function blist.get(list)
    local raw = tostring(util.job_get(S.blists, key(list)) or '')
    local out = {}
    for e in raw:gmatch('[^~]+') do
        local a = decode_action(e)
        if a.n ~= '' then out[#out + 1] = a end
    end
    return out
end
function blist.set(list, actions)
    S.blists = S.blists or {}
    local parts = {}
    for _, a in ipairs(actions) do parts[#parts + 1] = encode_action(a) end
    util.job_set(S.blists, key(list), table.concat(parts, '~'))
end
function blist.any(list)
    for _, a in ipairs(blist.get(list)) do if tonumber(a.on) == 1 then return true end end
    return false
end

-- what kind of thing a name is, and how it's used
local item_ids
local function item_by_name(n)
    if not item_ids then
        item_ids = {}
        for id, it in pairs(res.items) do if it.en then item_ids[it.en:lower()] = it end end
    end
    return item_ids[(n or ''):lower()]
end
function blist.kind(name)
    local sp = util.spell(name)
    if sp then return sp.type == 'Trust' and 'trust' or 'ma', sp end
    local ja = util.ability(name)
    if ja then return 'ja', ja end
    local ws = util.wskill(name)
    if ws then return 'ws', ws end
    if (name or ''):lower() == 'ranged attack' then return 'ra' end
    local it = item_by_name(name)
    if it then return 'item', it end
    return nil
end
local function on_enemy(kind, r)
    if kind == 'ws' or kind == 'ra' then return true end
    if not r then return false end
    return util.targets(r, 'Enemy') and not util.targets(r, 'Self')
end

local function has_status(player, name)
    local id = util.buff_id(name)
    return id and util.has_buff(player.buffs, id)
end

-- may this action go now? (its own conditions, not the recasts)
local function ok(a, player, mob)
    if tonumber(a.on) ~= 1 then return false end
    local v = player.vitals
    if v.hpp < a.pl or v.hpp > a.ph then return false end
    if (v.max_mp or 0) > 0 and (v.mpp < a.ml or v.mpp > a.mh) then return false end
    if v.tp < a.tpl or v.tp > a.tph then return false end
    if a.st ~= '' then
        local present = has_status(player, a.st)
        if tonumber(a.sp) == 1 then if not present then return false end elseif present then return false end
    end
    if mob then
        if (mob.hpp or 100) < a.tl or (mob.hpp or 100) > a.th then return false end
        if a.tn ~= '' and (mob.name or ''):lower() ~= a.tn:lower() then return false end
        if a.d > 0 and util.dist(mob) > a.d then return false end
        if a.lim > 0 then
            local used = ((state.blist_used or {})[mob.id] or {})[a.n] or 0
            if used >= a.lim then return false end
        end
    end
    if a.rc > 0 and h.recently('blist:' .. a.n, a.rc) then return false end
    return true
end

local function used(a, mob)
    h.mark('blist:' .. a.n)
    h.mark('blist:gcd')
    if mob then
        state.blist_used = state.blist_used or {}
        state.blist_used[mob.id] = state.blist_used[mob.id] or {}
        state.blist_used[mob.id][a.n] = (state.blist_used[mob.id][a.n] or 0) + 1
    end
end

-- try one action; true when it was sent
local function fire(a, player, mob, why)
    local kind, r = blist.kind(a.n)
    if not kind then return false end
    local tgt = on_enemy(kind, r) and '<t>' or '<me>'
    if tgt == '<t>' and not mob then return false end
    local done = false
    if kind == 'ma' or kind == 'trust' then
        if not util.spell_ready(r, player) then return false end
        done = h.try_cast(r.en, kind == 'trust' and '<me>' or tgt, why, player)
    elseif kind == 'ja' then
        if h.amnesia(player) or not util.ability_ready(r) then return false end
        done = h.use_ja(r, tgt)
    elseif kind == 'ws' then
        if h.amnesia(player) or player.vitals.tp < 1000 or player.status ~= 1 then return false end
        done = h.use_ws(r.en)
    elseif kind == 'item' then
        if h.recently('item:' .. r.en, 3) then return false end
        windower.send_command(('input /item "%s" %s'):format(r.en, tgt))
        h.mark('item:' .. r.en)
        done = true
    elseif kind == 'ra' then
        windower.send_command('input /ra <t>')
        done = true
    end
    if done then used(a, mob) end
    return done
end

local function gcd_ok()
    local g = (tonumber(S.farm.gcd) or 1000) / 1000
    return not h.recently('blist:gcd', g)
end

-- the first usable action of a list
function blist.try(list, player, mob, why)
    if not gcd_ok() then return false end
    for _, a in ipairs(blist.get(list)) do
        if ok(a, player, mob) and fire(a, player, mob, why or list) then return true end
    end
    return false
end

-- once-per-mob lists (start, finish): each action at most once for that mob
local function once(list, player, mob, tag)
    if not gcd_ok() then return false end
    state.blist_once = state.blist_once or {}
    local k = tag .. ':' .. tostring(mob and mob.id or 0)
    state.blist_once[k] = state.blist_once[k] or {}
    for _, a in ipairs(blist.get(list)) do
        if not state.blist_once[k][a.n] and ok(a, player, mob) then
            if fire(a, player, mob, list) then state.blist_once[k][a.n] = true return true end
        end
    end
    return false
end

-- trusts: call the list's trusts out of a fight until the party has trust_size members
local function party_size()
    local p = windower.ffxi.get_party() or {}
    local n = 0
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do if p[k] and p[k].name then n = n + 1 end end
    return n
end
local function in_party(name)
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        if p[k] and p[k].name and name:lower():find(p[k].name:lower(), 1, true) then return true end
    end
    return false
end

-- What the battle lists do this tick while farming. Returns true when it acted.
function blist.tick(player)
    if not S.modules.farm or not S.enabled then return false end
    local t = windower.ffxi.get_mob_by_target('t')
    local fighting = (player.status == 1 or state.farm_engageless) and t and (t.hpp or 0) > 0 and t.is_npc
    if fighting then
        -- a new mob: the start list first (each once)
        if state.blist_fight ~= t.id then state.blist_fight = t.id end
        if once('start', player, t, 'start') then return true end
        if blist.try('battle', player, t) then return true end
        return false
    end
    -- the mob we fought died: the finish list (each once)
    if state.blist_fight and state.blist_dead == state.blist_fight then
        local dead = { id = state.blist_fight, hpp = 0, name = state.blist_dead_name }
        if once('finish', player, nil, 'finish:' .. dead.id) then return true end
        state.blist_fight, state.blist_dead = nil, nil
    end
    -- out of a fight: healing on me, then trusts
    if player.status == 0 and blist.try('healing', player, nil) then return true end
    if player.status == 0 and party_size() < (tonumber(S.trusts and S.trusts.party_size) or 6) then
        for _, a in ipairs(blist.get('trusts')) do
            if tonumber(a.on) == 1 and not in_party(a.n) and gcd_ok() and ok(a, player, nil) and fire(a, player, nil, 'trust') then return true end
        end
    end
    return false
end

-- the weapon skill list (do_ws asks): the weapon skill to use now, or nil
function blist.ws(player, t)
    if not S.modules.farm or not blist.any('ws') then return nil end
    for _, a in ipairs(blist.get('ws')) do
        local kind, r = blist.kind(a.n)
        if kind == 'ws' and ok(a, player, t) and player.vitals.tp >= math.max(1000, a.tpl) then return a, r end
    end
    return 'hold'
end
function blist.ws_used(a, t) used(a, t) end

-- the pull list (vg_farm asks): the command to pull with now, its reach, or nil
function blist.pull(player, mob)
    if not blist.any('pull') then return nil end
    for _, a in ipairs(blist.get('pull')) do
        local kind, r = blist.kind(a.n)
        if kind and ok(a, player, mob) then
            local ready = true
            if kind == 'ma' then ready = util.spell_ready(r, player)
            elseif kind == 'ja' then ready = util.ability_ready(r) end
            if ready then
                local cmd = kind == 'ra' and 'input /ra <t>'
                    or ('input /%s "%s" <t>'):format(kind == 'trust' and 'ma' or kind, r and r.en or a.n)
                return cmd, a
            end
        end
    end
    return false
end
function blist.pull_used(a, mob) used(a, mob) end
function blist.reach()
    local best
    for _, a in ipairs(blist.get('pull')) do
        if tonumber(a.on) == 1 then best = math.max(best or 0, a.d > 0 and a.d or 20) end
    end
    return best
end

-- a kill (farm.on_kill): run the finish list next
function blist.on_kill(mob)
    if mob and state.blist_fight == mob.id then state.blist_dead, state.blist_dead_name = mob.id, mob.name end
end

-- the app's editor: //vg blist add <list> <name> | del <list> <i> | move <list> <i> up|down | set <list> <i> <field> <value>
function blist.command(args)
    local sub, list = (args[1] or ''):lower(), (args[2] or ''):lower()
    local valid = false
    for _, l in ipairs(blist.LISTS) do if l == list then valid = true end end
    if not valid then return false, 'unknown list' end
    local acts = blist.get(list)
    if sub == 'add' then
        local name = table.concat(args, ' ', 3)
        local kind, r = blist.kind(name)
        if not kind then return false, name .. ' is not an ability, spell, weapon skill or item' end
        local a = decode_action('n=' .. (r and r.en or name))
        if kind == 'ws' or kind == 'ja' and on_enemy(kind, r) then a.d = 4 end
        if kind == 'ma' and on_enemy(kind, r) then a.d = 20 end
        acts[#acts + 1] = a
    elseif sub == 'del' then
        table.remove(acts, tonumber(args[3]) or 0)
    elseif sub == 'move' then
        local i = tonumber(args[3]) or 0
        local j = (args[4] or ''):lower() == 'up' and i - 1 or i + 1
        if acts[i] and acts[j] then acts[i], acts[j] = acts[j], acts[i] end
    elseif sub == 'set' then
        local i, f, v = tonumber(args[3]) or 0, args[4], table.concat(args, ' ', 5)
        local a = acts[i]
        if not a or a[f] == nil then return false, 'no such action / field' end
        if type(a[f]) == 'number' then a[f] = tonumber(v) or a[f] else a[f] = v end
    else
        return false, 'usage'
    end
    blist.set(list, acts)
    return true
end

-- everything, for the app: { start = { {n=, on=, d=, ...}, ... }, ... }
function blist.all()
    local out = {}
    for _, l in ipairs(blist.LISTS) do out[l] = blist.get(l) end
    return out
end

function blist.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return blist
