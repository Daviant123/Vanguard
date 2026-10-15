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

local function send(tbl)
    if not bridge.udp then return end
    bridge.udp:sendto(util.json(tbl), bridge.host, bridge.port)
end

function bridge.send(tbl) send(tbl) end

function bridge.log(text)
    local p = windower.ffxi.get_player()
    send({ type = 'log', name = p and p.name or '?', text = text })
end

local function snapshot(settings)
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
    end
    -- Outgoing status
    if now() - bridge.last_send >= settings.bridge.interval then
        bridge.last_send = now()
        local snap = snapshot(settings)
        if snap then send(snap) end
    end
end

return bridge
