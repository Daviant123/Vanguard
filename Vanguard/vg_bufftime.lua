--[[
Vanguard: recasting buffs before they wear off (his request 2026-10-27: "give more controls on the buffs tab, so that
user can manually select a time to recast the buffs, before they fall off").

  buffs.before   seconds before a buff wears off to cast it again (0 = when it has worn off, as before)
  buffs.times    per buff, beats buffs.before: "Haste=45,Refresh=60" (by name without the tier: Protect V -> Protect)
  buffs.learned  how long each buff really lasts on party members, learned here: "Haste=212,Refresh=171"

How long is left: on ourselves the game's own timers (packet 0x063, the same ones the bard uses). On party members the
game sends no timers, so it's counted from when our cast landed on them, with the length learned from the last time it
wore off (gear, merits, Composure, Perpetuance all included) - until then the spell's base duration (shorter than with
gear: it recasts a little early rather than late).
]]
local util = require('vg_util')

local bt = {}
local S, state, h

local function clock() return os.clock() end
local function family(name) return (tostring(name or ''):gsub('%s+[IVX]+$', '')) end

local function parse(str)
    local out = {}
    for part in tostring(str or ''):gmatch('[^,;]+') do
        local k, v = part:match('^%s*(.-)%s*=%s*(%d+)%s*$')
        if k and k ~= '' then out[k:lower()] = tonumber(v) end
    end
    return out
end
local function encode(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. math.floor(t[k] + 0.5) end
    return table.concat(parts, ',')
end

-- seconds before the end to cast it again (0 = only when it's gone)
function bt.before(spell_name)
    local per = parse(S.buffs.times)
    local v = per[family(spell_name):lower()] or per[tostring(spell_name):lower()]
    if v then return v end
    return tonumber(S.buffs.before) or 0
end

-- how long it lasts on a party member: learned, else the spell's base duration
function bt.length(spell)
    local l = parse(S.buffs.learned)[spell.en:lower()]
    return l or spell.duration
end

-- Our buff spell landed on someone (from the action packet): start their timer.
function bt.on_land(spell, target)
    if not spell or not spell.status or not target or target == '' then return end
    state.buff_land = state.buff_land or {}
    local k = target:lower()
    state.buff_land[k] = state.buff_land[k] or {}
    state.buff_land[k][spell.status] = { at = clock(), spell = spell.en }
end

-- Seen it gone from a member (do_buffs): learn how long it lasted, if it ran its course since our cast.
function bt.on_gone(spell, target)
    local rec = state.buff_land and state.buff_land[target:lower()] and state.buff_land[target:lower()][spell.status]
    if not rec then return end
    state.buff_land[target:lower()][spell.status] = nil
    local lasted = clock() - rec.at
    local base = spell.duration or 0
    -- a sane length (not dispelled after 5 s, not something missed for ages): from 60 % of the base to 6 times it
    if base > 0 and lasted >= base * 0.6 and lasted <= base * 6 then
        local t = parse(S.buffs.learned)
        local old = t[spell.en:lower()]
        t[spell.en:lower()] = old and (old * 0.5 + lasted * 0.5) or lasted
        S.buffs.learned = encode(t)
        if h.save then pcall(h.save) end
    end
end

-- Seconds left of this buff on target (nil: unknown).
function bt.left(spell, target, is_self)
    if is_self then
        local b = require('vg_bard')
        return spell.status and b.buff_left and b.buff_left(spell.status) or nil
    end
    local rec = state.buff_land and state.buff_land[target:lower()] and state.buff_land[target:lower()][spell.status]
    local len = bt.length(spell)
    if not rec or not len then return nil end
    return rec.at + len - clock()
end

-- For the app: the learned lengths ({ name = secs }) and the per-buff times.
function bt.info()
    return { learned = parse(S.buffs.learned), times = parse(S.buffs.times), before = tonumber(S.buffs.before) or 0 }
end

-- //vg bufftime <spell> <seconds|default>
function bt.set(name, secs)
    local t = parse(S.buffs.times)
    local key = family(name):lower()
    if secs == nil or secs == 'default' or secs == '' then t[key] = nil else t[key] = tonumber(secs) end
    S.buffs.times = encode(t)
end

function bt.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return bt
