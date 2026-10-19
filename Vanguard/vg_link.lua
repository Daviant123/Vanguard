--[[
Vanguard link: Vanguard Control is where everything is chosen and kept (user request 2026-10-15: "it can all be
done from the application, I don't really want to rely on the addon"). The app saves a character's whole setup as
a profile file on the PC and puts it back on any character; the addon just carries it out.

  dump     (from the app)   the addon answers {"type":"dump", ...} with everything a profile needs: the job's role,
                            weapon skill, ability on/off + thresholds, menus (buffs, songs, geo, enfeebles, modules)
                            and the settings sections below.
  cfg      (from the app)   "cfg <json>": put a profile back. Only known settings with the right type are taken;
                            the job part applies now if the character is on that job, otherwise when it changes to it.
  actopt <id> <key> <v>     one ability's threshold (hpp_below, mpp_below, mpp_above, tp_min, tp_max, party_below,
                            cooldown, when); "default" puts the job's recommended value back.
]]

local util = require('vg_util')

local link = {}
local S, state, h

-- Settings sections a profile carries (the menus carry buffs / songs / geo spells / enfeebles / modules).
local SECTIONS = {
    heal = true, cleanse = true, rest = true, mana = true, trusts = true, ws = true, assist = true, follow = true,
    alts = true, upkeep = true, mount = true, gear = true, away = true, share = true, alerts = true, mages = true,
    cor = true, burst = true, strat = true,
    debuff = { retries = true },
    songs = { duration = true, refresh_before = true, when = true, nitro = true, marcato = true, pianissimo = true,
              slots = true, dummy = true, marcato_song = true, clarion_song = true, aoe_names = true },
    geo = { entrust = true, full_circle_range = true, hate_first = true, party_mp = true },
}
link.SECTIONS = SECTIONS

-- Ability fields the app may change.
link.OPT_KEYS = { hpp_below = 'number', mpp_below = 'number', mpp_above = 'number', tp_min = 'number',
                  tp_max = 'number', party_below = 'number', cooldown = 'number', when = 'string', pet_hpp_below = 'number' }
local WHEN = { always = true, combat = true, engaged = true, idle = true }

local function copy(v)
    if type(v) ~= 'table' then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

function link.dump(player)
    h.save_profile()
    local job = player.main_job
    local out = { job = job, sub = player.sub_job, profile = util.job_get(S.profiles, job) or '', menu = util.job_get(S.menus, job) or '',
                  leader = S.leader, settings = {} }
    for sec, keys in pairs(SECTIONS) do
        if type(S[sec]) == 'table' then
            local t = {}
            for k, v in pairs(S[sec]) do
                if (keys == true or keys[k]) and type(v) ~= 'function' then t[k] = copy(v) end
            end
            out.settings[sec] = t
        end
    end
    return out
end

-- Put a profile back. Returns a short description of what happened.
function link.apply(player, p)
    if type(p) ~= 'table' or type(p.job) ~= 'string' or not p.job:match('^%u%u%u$') then return nil, 'not a profile' end
    local changed = 0
    for sec, vals in pairs(type(p.settings) == 'table' and p.settings or {}) do
        local keys = SECTIONS[sec]
        if keys and type(S[sec]) == 'table' and type(vals) == 'table' then
            for k, v in pairs(vals) do
                local cur = S[sec][k]
                if (keys == true or keys[k]) and cur ~= nil and type(cur) == type(v) then
                    if type(v) == 'table' then
                        for kk, vv in pairs(v) do
                            if cur[kk] ~= nil and type(cur[kk]) == type(vv) then cur[kk] = vv changed = changed + 1 end
                        end
                    else
                        S[sec][k] = v
                        changed = changed + 1
                    end
                end
            end
        end
    end
    if type(p.profile) == 'string' and p.profile ~= '' then util.job_set(S.profiles, p.job, p.profile) end
    if type(p.menu) == 'string' and p.menu ~= '' then util.job_set(S.menus, p.job, p.menu) end
    h.store(S)
    if player.main_job == p.job then
        h.load_profile(player)
        return ('applied (%d settings)'):format(changed)
    end
    return ('saved for %s: it applies when this character is on %s'):format(p.job, p.job)
end

function link.on_cfg(player, json)
    local p, err = util.json_decode(json)
    if not p then h.log('Profile from Vanguard Control could not be read: ' .. tostring(err)) return end
    local msg, why = link.apply(player, p)
    h.log(('Profile %s: %s'):format(type(p.name) == 'string' and ('"' .. p.name .. '"') or 'from Vanguard Control', msg or why))
end

-- //vg actopt <id> <key> <value|default>
function link.actopt(pr, id, key, value)
    if not pr or not id or not link.OPT_KEYS[key or ''] then
        h.log('Usage: //vg actopt <ability id> hpp_below|mpp_below|mpp_above|tp_min|tp_max|party_below|pet_hpp_below|cooldown|when <value|default>')
        return false
    end
    pr.opts = pr.opts or {}
    pr.opts[id] = pr.opts[id] or {}
    if value == nil or value == 'default' then
        pr.opts[id][key] = nil
    elseif link.OPT_KEYS[key] == 'number' then
        local n = tonumber(value)
        if not n then h.log('Not a number: ' .. tostring(value)) return false end
        pr.opts[id][key] = n
    else
        if not WHEN[value] then h.log('when: always | combat | engaged | idle') return false end
        pr.opts[id][key] = value
    end
    if next(pr.opts[id]) == nil then pr.opts[id] = nil end
    return true
end

-- Profile string part: o=id:key~val:key~val+id2:...   ('+' and ':' because commas are split by the config library)
function link.encode_opts(opts)
    local parts = {}
    for id, o in pairs(opts or {}) do
        local kv = {}
        for k, v in pairs(o) do kv[#kv + 1] = k .. '~' .. tostring(v) end
        table.sort(kv)
        if #kv > 0 then parts[#parts + 1] = id .. ':' .. table.concat(kv, ':') end
    end
    table.sort(parts)
    return table.concat(parts, '+')
end

function link.decode_opts(str)
    local opts = {}
    for _, entry in ipairs(util.split(str or '', '+')) do
        local id, rest = entry:match('^([%w_]+):(.+)$')
        if id then
            for k, v in rest:gmatch('([%w_]+)~([^:]+)') do
                if link.OPT_KEYS[k] == 'number' then v = tonumber(v) end
                if v ~= nil and link.OPT_KEYS[k] then
                    opts[id] = opts[id] or {}
                    opts[id][k] = v
                end
            end
        end
    end
    return opts
end

function link.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return link
