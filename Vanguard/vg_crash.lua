--[[
Vanguard: crash reports (user request 2026-10-16: "build something in that gets crash reports and reports them back
to me so they can be rectified"). Every event handler and the main loop run guarded: an error no longer just prints
red text in one game window - it's caught with where it happened and a stack trace, told once in chat, and sent to
Vanguard Control, which keeps it and lets the player send a report to the GitHub page with one click (character
names and Windows user names are taken out first). Nothing leaves the PC unless the player clicks Send report.

Never yields: guarded code must not coroutine.sleep (Windower can't yield across pcall); Vanguard doesn't.
]]

local crash = {}
local bridge
local recent = {}          -- [where .. err] = os.clock() last reported (one report a minute per problem)

local function clock() return os.clock() end

function crash.report(where, err, trace)
    err = tostring(err)
    local key = where .. '|' .. err
    if recent[key] and clock() - recent[key] < 60 then return end
    recent[key] = clock()
    local p = windower.ffxi.get_player()
    windower.add_to_chat(167, ('[Vanguard] Something went wrong (%s): %s'):format(where, err))
    windower.add_to_chat(167, '[Vanguard] Vanguard Control can send a report so it gets fixed (App & updates > Problems).')
    if bridge then
        pcall(bridge.send, { type = 'crash', name = p and p.name or '?', version = _addon.version,
            job = p and ((p.main_job or '?') .. '/' .. (p.sub_job or '-')) or '?',
            where = where, err = err, trace = tostring(trace or '') })
    end
end

local unpack_ = rawget(_G, 'unpack') or rawget(table, 'unpack')     -- Lua 5.1 / LuaJIT has unpack; newer Lua table's
local function pack(...) return { n = select('#', ...), ... } end
local function on_error(e) return { e = e, tb = debug.traceback(tostring(e), 2) } end

-- fn wrapped so an error is reported instead of breaking; returns fn's results when all is well.
-- (LuaJIT's xpcall passes the extra arguments on, like newer Lua's.)
function crash.guard(where, fn)
    return function(...)
        local res = pack(xpcall(fn, on_error, ...))
        if res[1] then return unpack_(res, 2, res.n) end
        local info = res[2]
        if type(info) == 'table' then crash.report(where, info.e, info.tb) else crash.report(where, info) end
        return nil
    end
end

function crash.init(bridge_module)
    bridge = bridge_module
end

return crash
