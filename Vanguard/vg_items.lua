--[[
A small item index: what Vanguard needs to know about items (name, category, type, weapon skill, shield size) without
loading Windower's whole item list.

CharC's crashes ("not enough memory", 2026-10-30 and 2026-11-11, GitHub issues #2-#5): require('resources').items
loads res/items.lua (5 MB of text, 23,000 items with Japanese names, descriptions' flags, levels, jobs...) as one big
table, many times its file size, inside the game. With several addons doing the same in one game, Lua ran out of memory
right when Vanguard sent its setup to the app (the item picker's inventory names). This reads the file one line at a time
and keeps only the few fields above, on first use. If the file can't be read, it falls back to the resources library.
]]

local items = {}

local loaded = false
local en, enl, category, kind, skill, shield = {}, {}, {}, {}, {}, {}
local by_name = {}          -- lower-case en / enl name -> id

local function unescape(s) return (s:gsub('\\(.)', '%1')) end

local function from_resources()
    local ok, res = pcall(require, 'resources')
    local all = ok and res and res.items
    if type(all) ~= 'table' then return end
    for id, it in pairs(all) do
        if type(it) == 'table' and it.en then
            en[id], enl[id], category[id], kind[id], skill[id], shield[id] = it.en, it.enl, it.category, it.type, it.skill, it.shield_size
        end
    end
end

local function load()
    if loaded then return end
    loaded = true
    local path = rawget(_G, 'VG_ITEMS_FILE') or ((windower.windower_path or '') .. 'res/items.lua')   -- (tests: the real file)
    local f = io.open(path, 'r')
    if not f then from_resources() else
        f:close()
        local cats = {}     -- one copy of each category string
        for line in io.lines(path) do
            local id, rest = line:match('^%s*%[(%d+)%]%s*=%s*{(.*)}')
            if id then
                id = tonumber(id)
                local n = rest:match(',en="(.-)",ja="')
                if n then
                    en[id] = unescape(n)
                    local l = rest:match(',enl="(.-)",jal="')
                    if l then enl[id] = unescape(l) end
                    local c = rest:match(',category="(%a+)"')
                    if c then cats[c] = cats[c] or c category[id] = cats[c] end
                    kind[id] = tonumber(rest:match(',type=(%d+)'))
                    skill[id] = tonumber(rest:match(',skill=(%d+)'))
                    shield[id] = tonumber(rest:match(',shield_size=(%d+)'))
                end
            end
        end
    end
    for id, n in pairs(en) do
        by_name[n:lower()] = by_name[n:lower()] or id
    end
    for id, n in pairs(enl) do
        by_name[n:lower()] = by_name[n:lower()] or id
    end
end

-- {id, en, enl, category, type, skill, shield_size} or nil
function items.get(id)
    id = tonumber(id)
    if not id or id == 0 then return nil end
    load()
    if not en[id] then return nil end
    return { id = id, en = en[id], enl = enl[id], category = category[id], type = kind[id], skill = skill[id], shield_size = shield[id] }
end

function items.name(id)
    load()
    return en[tonumber(id) or -1]
end

-- id for a name (any case; the long name "pile of chocobo bedding" too)
function items.id(name)
    if type(name) ~= 'string' or name == '' then return nil end
    load()
    return by_name[name:lower()]
end

return items
