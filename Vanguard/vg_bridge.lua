--[[
Vanguard bridge: talks to the Vanguard Control desktop app over local UDP.

  addon -> app : JSON status snapshots every settings.bridge.interval seconds,
                 plus {"type":"log"} lines.
  app -> addon : plain text "cmd <vg command>", e.g. "cmd follow on".

Only 127.0.0.1 is used by default; nothing leaves your PC.
]]

local util = require('vg_util')
local res = require('resources')

local ok_socket, socket = pcall(require, 'socket')

local bridge = { udp = nil, last_send = 0, queue = {} }

local function now() return os.clock() end

function bridge.start(settings)
    if not ok_socket or not settings.bridge.enabled then return end
    local udp = socket.udp()
    udp:settimeout(0)
    udp:setsockname('127.0.0.1', 0)
    bridge.udp = udp
    bridge.host, bridge.port = settings.bridge.host, settings.bridge.port
end

function bridge.stop()
    if bridge.udp then bridge.udp:close() bridge.udp = nil end
end

-- Messages bigger than one UDP packet here (8 KB; a main Scholar's profile is ~14 KB) go in parts:
-- "vgpart <id> <i>/<n> <text>", put back together by Vanguard Control.
local PART = 8000                -- + a short header: stays under 8192
function bridge.pack(text)
    if #text <= PART then return { text } end
    bridge.msgid = (bridge.msgid or 0) % 100000 + 1
    local n = math.ceil(#text / PART)
    local out = {}
    for i = 1, n do
        out[i] = ('vgpart %d %d/%d '):format(bridge.msgid, i, n) .. text:sub((i - 1) * PART + 1, i * PART)
    end
    return out
end

local function send(tbl)
    if not bridge.udp then return end
    for _, msg in ipairs(bridge.pack(util.json(tbl))) do
        bridge.udp:sendto(msg, bridge.host, bridge.port)
    end
end

function bridge.send(tbl) send(tbl) end

function bridge.log(text)
    local p = windower.ffxi.get_player()
    send({ type = 'log', name = p and p.name or '?', text = text })
end

-- Enemy watch (series 3 round 4): the battle target and how the team's enfeebles stand on it - landed, resisted,
-- being cast (shared between characters, vg_share), or not tried yet - plus its last TP move.
function bridge.foe(settings, state)
    local bt = windower.ffxi.get_mob_by_target('bt')
    if not bt or (bt.hpp or 0) <= 0 then return nil end
    local rec = state and state.debuffs and state.debuffs[bt.id] or {}
    local effects, seen = {}, {}
    local function add(name, r)
        if seen[name] then return end
        seen[name] = true
        local st = 'wanted'
        if r then
            if r.landed then st = 'landed'
            elseif r.other_until and os.clock() < r.other_until then st = 'casting'
            elseif r.resisted or (r.tries or 0) > 0 then st = 'resisted' end
        end
        effects[#effects + 1] = { n = name, s = st }
    end
    for _, name in ipairs(settings.modules.debuff and util.split(settings.debuff.list, ',') or {}) do add(name, rec[name]) end
    for name, r in pairs(rec) do if type(r) == 'table' then add(name, r) end end
    return { id = bt.id, name = bt.name, hpp = bt.hpp, d = math.floor(util.dist(bt) + 0.5), effects = effects,
             move = require('vg_triggers').last_move(6) }
end

local function snapshot(settings, state)
    local p = windower.ffxi.get_player()
    if not p then return nil end
    local info = windower.ffxi.get_info()
    local t = windower.ffxi.get_mob_by_target('t')
    return {
        type = 'state',
        name = p.name,
        job = (p.main_job or '?') .. (p.main_job_level or '') .. '/' .. (p.sub_job or '-') .. (p.sub_job_level or ''),
        hpp = p.vitals.hpp, mpp = p.vitals.mpp, tp = p.vitals.tp,
        hp = p.vitals.hp, mp = p.vitals.mp,
        status = ({[0] = 'Idle', [1] = 'Engaged', [2] = 'Dead', [3] = 'Dead', [33] = 'Resting'})[p.status] or tostring(p.status),
        zone = info and res.zones[info.zone] and res.zones[info.zone].en or '?',
        target = t and t.name or '',
        target_hpp = t and t.hpp or 0,
        enabled = settings.enabled,
        leader = settings.leader,
        modules = settings.modules,
        version = _addon.version,
        autostart = settings.autostart,
        stats = require('vg_stats').get(),
        buffs = util.buff_list(p.buffs),
        foe = bridge.foe(settings, state),
        hold = state and state.hold or false,
        camp = state and state.camp ~= nil or false,
        retreat = state and state.retreat or false,
        away = state and state.away or false,
        defense = state and state.defense or 'off',
        strat = state and state.strat_now or nil,
    }
end

function bridge.poll(settings, state)
    if not bridge.udp then return end
    -- Incoming commands
    for _ = 1, 10 do
        local data = bridge.udp:receive()
        if not data then break end
        local cmd = data:match('^cmd (.+)$')
        if cmd then windower.send_command('vg ' .. cmd) end
        local n, total, part = data:match('^cfg (%d+)/(%d+) (.*)$')
        if n then
            n, total = tonumber(n), tonumber(total)
            if n == 1 then bridge.parts = {} end
            bridge.parts = bridge.parts or {}
            bridge.parts[n] = part
            if n == total and #bridge.parts == total and bridge.on_cfg then
                local json = table.concat(bridge.parts)
                bridge.parts = nil
                bridge.on_cfg(json)
            end
        end
    end
    -- Outgoing status
    if now() - bridge.last_send >= settings.bridge.interval then
        bridge.last_send = now()
        local snap = snapshot(settings, state)
        if snap then send(snap) end
    end
end

return bridge
