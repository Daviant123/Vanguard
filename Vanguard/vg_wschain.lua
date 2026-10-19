--[[
Vanguard: a weapon skill chain for one character (his request 2026-10-19: add the AutoSkillchain addon to Vanguard).
Like Ameilia's AutoSkillchain: a list of weapon skills used in turn - each when TP is 1000+ (ws.tp if higher), at
least 4 s after the last one, from melee range (or 22' for a ranged weapon skill) - repeating, or stopping at the end
(then the normal weapon skill again). A new mob, or 20 s without the next one (the skillchain is broken), starts it
over from the first. Normal /ws commands only.
  wschains[job]    "1|Savage Blade,Chant du Cygne,Requiescat"  (per job; 1 = repeat, 0 = stop at the end)
Chains saved in AutoSkillchain (addons/AutoSkillchain/data/<JOB>/<weapon type>.lua) can be loaded with one click.
]]
local util = require('vg_util')
local res = require('resources')

local wschain = {}
local S, state, h

local function clock() return os.clock() end
local function job() local p = windower.ffxi.get_player() return p and p.main_job end
local function raw() return tostring(util.job_get(S.wschains, job()) or '') end
local function list()
    local r = raw()
    return util.split(r:match('^%d|(.*)$') or r, ',')
end
function wschain.list() return list() end
function wschain.rep() return raw():sub(1, 1) ~= '0' end
function wschain.set(ws, rep)
    S.wschains = S.wschains or {}
    util.job_set(S.wschains, job(), #ws > 0 and ((rep and '1|' or '0|') .. table.concat(ws, ',')) or '')
    state.wschain = nil
end

-- The weapon skill to use now, 'hold' (chain set, not yet), or nil (no chain, or it ran to its end: normal WS).
function wschain.next(player, t)
    local ws = list()
    if #ws == 0 or not t then return nil end
    state.wschain = state.wschain or { i = 1, target = nil, last = -100 }
    local c = state.wschain
    if c.target ~= t.id or clock() - c.last > 20 then c.i, c.target = 1, t.id end
    if c.i > #ws then return nil end                           -- ran to its end (no repeat): normal weapon skill
    local need = math.max(1000, tonumber(S.ws.tp) or 1000)
    if player.vitals.tp < need or clock() - c.last < 4 then return 'hold' end
    local w = util.wskill(ws[c.i])
    if not w then c.i = c.i + 1 return 'hold' end              -- not a weapon skill (renamed / mistyped): skip it
    local reach = (w.range == 12) and 21.99 or (tonumber(S.ws.max_range) or 6)
    if util.dist(t) > reach then return 'hold' end
    return w.en
end

-- Called after the chain's weapon skill was sent.
function wschain.used()
    local c = state.wschain
    if not c then return end
    c.last = clock()
    c.i = c.i + 1
    if c.i > #list() and wschain.rep() then c.i = 1 end
end

-- What step it's on, for the app.
function wschain.step()
    local c = state.wschain
    return c and c.i or 1
end

------------------------------------------------------------------------
-- Chains saved in AutoSkillchain, for this job and the main weapon's type
------------------------------------------------------------------------
local BAGS = { [0] = 'inventory', [8] = 'wardrobe', [10] = 'wardrobe2', [11] = 'wardrobe3', [12] = 'wardrobe4',
               [13] = 'wardrobe5', [14] = 'wardrobe6', [15] = 'wardrobe7', [16] = 'wardrobe8' }
local function weapon_type()
    local items = windower.ffxi.get_items() or {}
    local eq = items.equipment
    if type(eq) ~= 'table' or not eq.main or eq.main == 0 then return 'Hand-to-Hand' end
    local bag = items[BAGS[eq.main_bag] or 'inventory']
    local it = type(bag) == 'table' and bag[eq.main]
    local item = it and res.items[it.id]
    local skill = item and item.skill and res.skills[item.skill]
    return skill and skill.en or 'Hand-to-Hand'
end

-- AutoSkillchain's files are Lua tables with L{...} lists: read as text (nothing from them is run)
function wschain.parse(text)
    local out = {}
    local body = type(text) == 'string' and text:match('return%s*(%b{})')
    if not body then return out end
    for blk in body:sub(2, -2):gmatch('%b{}') do
        local name = blk:match("%[%s*['\"]name['\"]%s*%]%s*=%s*['\"](.-)['\"]")
        local rep = blk:match("%[%s*['\"]repeat['\"]%s*%]%s*=%s*(%a+)") == 'true'
        local ws_txt = blk:match("%[%s*['\"]ws['\"]%s*%]%s*=%s*L?%s*(%b{})")
        if name and ws_txt then
            local ws = {}
            for q in ws_txt:gmatch("'([^']*)'") do ws[#ws + 1] = (q:gsub('"', '')) end
            if #ws == 0 then for q in ws_txt:gmatch('"([^"]*)"') do ws[#ws + 1] = q end end
            if #ws > 0 then out[#out + 1] = { name = name, ws = ws, rep = rep } end
        end
    end
    return out
end

local cache = { t = -100 }
function wschain.presets(player)
    local key = (player.main_job or '') .. '/' .. weapon_type()
    if cache.key == key and clock() - cache.t < 60 then return cache.list end
    local path = (windower.windower_path or '') .. 'addons/AutoSkillchain/data/' .. key .. '.lua'
    local f = io.open(path, 'r')
    local list_ = {}
    if f then
        list_ = wschain.parse(f:read('*a'))
        f:close()
    end
    cache.key, cache.t, cache.list = key, clock(), list_
    return list_
end
function wschain.weapon_type() return weapon_type() end

function wschain.load(player, name)
    for _, p in ipairs(wschain.presets(player)) do
        if p.name:lower() == (name or ''):lower() then
            wschain.set(p.ws, p.rep)
            return p
        end
    end
    return nil
end

function wschain.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return wschain
