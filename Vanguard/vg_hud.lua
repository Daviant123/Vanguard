--[[
Vanguard: alt overview box on the leader's screen (round 3, 2026-10-15; after FastFollow's distance box
and CurePlease's party view).

Each alt sends a short status line over Windower's local IPC every 2 seconds:
  "vg_status <name> <leader> <job> <hpp> <mpp> <tp> <distance> <doing>"
The character they follow shows them in one small box:
  CharB         WHM/SCH  HP 100  MP  82  TP    0    3y  following
  CharC  BRD/WHM  HP  64  MP  40  TP  950    2y  fighting
Red when KO'd / low / far, grey when an alt has gone quiet. Drag the box to move it.
  //vg hud on|off
]]

local texts = require('texts')

local hud = { alts = {} }
local S, state, h
local box
local last_send, last_draw = -100, -100

local function clock() return os.clock() end

-- What this character is doing, in a word.
local function doing(player)
    if player.status == 2 or player.status == 3 then return 'KO' end
    if player.status == 33 then return 'resting' end
    if player.status == 1 then return 'fighting' end
    if state.hold then return 'holding' end
    if state.camp then return 'camp' end
    for _, b in ipairs(player.buffs or {}) do if b == 252 then return 'mounted' end end
    if state.running then return 'following' end
    return 'idle'
end

-- On the alt: send my status to my leader every 2 s.
function hud.send(player)
    if S.leader == '' or S.leader:lower() == player.name:lower() or clock() - last_send < 2 then return end
    last_send = clock()
    local v = player.vitals or {}
    local l = windower.ffxi.get_mob_by_name(S.leader)
    local d = l and math.floor(math.sqrt(l.distance or 0) + 0.5) or -1
    windower.send_ipc_message(('vg_status %s %s %s/%s %d %d %d %d %s'):format(player.name, S.leader,
        player.main_job or '?', player.sub_job or '-', v.hpp or 0, (v.max_mp or 0) > 0 and (v.mpp or 0) or -1,
        v.tp or 0, d, doing(player)))
end

-- On every character: keep the statuses meant for me.
function hud.on_status(player, name, leader, job, hpp, mpp, tp, dist, what)
    if leader:lower() ~= player.name:lower() then return end
    hud.alts[name] = { job = job, hpp = tonumber(hpp), mpp = tonumber(mpp), tp = tonumber(tp),
                       dist = tonumber(dist), doing = what, t = clock() }
end

local RED, GREY, GREEN = '\\cs(240,110,100)', '\\cs(140,140,150)', '\\cs(120,210,140)'

function hud.lines()
    local names = {}
    for name in pairs(hud.alts) do names[#names + 1] = name end
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        local a = hud.alts[name]
        local stale = clock() - a.t > 10
        local line = ('%-13s %-8s HP %3d  MP %s  TP %4d  %s  %s'):format(name:sub(1, 13), a.job, a.hpp,
            a.mpp >= 0 and ('%3d'):format(a.mpp) or '  -', a.tp, a.dist >= 0 and ('%3dy'):format(a.dist) or ' ---',
            stale and '(no word)' or a.doing)
        local bad = a.doing == 'KO' or a.hpp < (tonumber(S.alerts.hp) or 30) or (a.mpp >= 0 and a.mpp < (tonumber(S.alerts.mp) or 10))
            or a.dist < 0 or a.dist > (tonumber(S.alerts.far) or 30)
        out[#out + 1] = { text = line, color = stale and GREY or (bad and RED or nil) }
    end
    return out
end

-- On the leader: draw the box once a second (hidden when nobody reports to me).
function hud.draw()
    if clock() - last_draw < 1 then return end
    last_draw = clock()
    for name, a in pairs(hud.alts) do if clock() - a.t > 60 then hud.alts[name] = nil end end
    local lines = hud.lines()
    if not S.alts.hud or #lines == 0 then
        if box then box:hide() end
        return
    end
    if not box then
        box = texts.new('', { pos = { x = S.hud.x, y = S.hud.y }, bg = { alpha = 190, red = 18, green = 20, blue = 26 },
            text = { font = 'Consolas', size = 10 }, flags = { draggable = true }, padding = 4 })
    end
    local t = { GREEN .. 'Vanguard alts\\cr' }
    for _, l in ipairs(lines) do t[#t + 1] = l.color and (l.color .. l.text .. '\\cr') or l.text end
    box:text(table.concat(t, '\n'))
    box:show()
    hud.text = table.concat(t, '\n')
end

function hud.destroy() if box then box:destroy() box = nil end end

function hud.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return hud
