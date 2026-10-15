--[[
Vanguard settings saving that is safe with several characters running Vanguard at once.

Windower's config library rewrites the whole settings.xml from what THIS game instance read when it
loaded, so a plain settings:save() on one character quietly reverts the other characters' newer
changes (menu ticks, job setups, leader). store.save first re-reads the file, puts this character's
values back on top, then saves. (Same fix as Steward's st_store, 2026-10-12.)
]]

local config = require('config')

local store = {}

local function copy(v)
    if type(v) ~= 'table' then return v end
    local t = {}
    for k, x in pairs(v) do if type(x) ~= 'function' then t[k] = copy(x) end end
    return t
end

local function assign(dst, src)
    for k, v in pairs(src) do
        if type(v) == 'table' and type(rawget(dst, k)) == 'table' then assign(rawget(dst, k), v)
        else rawset(dst, k, v) end
    end
end

function store.save(settings)
    if not settings then return end
    local mine = {}
    for k, v in pairs(settings) do if type(v) ~= 'function' then mine[k] = copy(v) end end
    if type(config.reload) == 'function' then
        pcall(config.reload, settings)
        assign(settings, mine)
    end
    return settings:save()
end

return store
