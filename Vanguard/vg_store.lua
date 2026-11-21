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

-- after the re-read, this character's values must be exactly what it had: anything it removed (a deleted team
-- setup, a cleared list entry) must not come back from the file
local function mirror(dst, src)
    for k, v in pairs(dst) do
        if type(v) ~= 'function' then
            if src[k] == nil then rawset(dst, k, nil)
            elseif type(v) == 'table' and type(src[k]) == 'table' then mirror(v, src[k]) end
        end
    end
end

--[[ Lists where text belongs (CharA's crash 2026-11-09: "attempt to compare string with number" in config's
nest_xml, every save failing). Windower's config reads an empty entry back as an empty table, and when the file
later holds text with commas for it (a priority order "fighting,cures,...", a weapon skill chain) it splits the
text into a numbered list {1 = 'fighting', 2 = 'cures', ...}. A list read back with more items than the one in
memory gets text keys "13", "14" next to the number keys, and config can't sort those keys to write the file.
No Vanguard setting is a list: everything saved is text, numbers or true/false. So tidy turns a list back into
its text (joined with ',', as config split it), and drops number keys anywhere else. Done after every load,
reload and before every save. ]]
local TEXT = { 'charm_sleeps', 'profiles', 'menus', 'priorities', 'customs', 'blists', 'wschains', 'wschains_mine', 'trials',
    'triggers', 'farmspots', 'cure_learn', 'cure_off' }

local function as_text(v)
    local parts = {}
    for k, x in pairs(v) do
        local n = tonumber(k)
        if n and type(x) ~= 'table' then parts[#parts + 1] = { n, tostring(x) } end
    end
    table.sort(parts, function(a, b) return a[1] < b[1] end)
    local out = {}
    for i, p in ipairs(parts) do out[i] = p[2] end
    return table.concat(out, ',')
end

local function drop_numbers(t)
    local has_text, nums = false, {}
    for k in pairs(t) do if type(k) == 'number' then nums[#nums + 1] = k elseif type(k) == 'string' then has_text = true end end
    if #nums > 0 and has_text then for _, k in ipairs(nums) do rawset(t, k, nil) end end
    for k, v in pairs(t) do
        if type(v) == 'table' then
            if next(v) ~= nil and rawget(v, 1) ~= nil then
                local only_numbers = true
                for kk in pairs(v) do if type(kk) ~= 'number' then only_numbers = false break end end
                if only_numbers then rawset(t, k, as_text(v)) else drop_numbers(v) end
            else drop_numbers(v) end
        end
    end
end

function store.tidy(settings)
    if type(settings) ~= 'table' then return settings end
    for _, name in ipairs(TEXT) do
        local t = rawget(settings, name)
        if type(t) == 'table' then
            for k, v in pairs(t) do if type(v) == 'table' then rawset(t, k, as_text(v)) end end
        end
    end
    local setups = rawget(settings, 'setups')
    if type(setups) == 'table' then
        for _, s in pairs(setups) do
            if type(s) == 'table' then
                for k, v in pairs(s) do if type(v) == 'table' then rawset(s, k, as_text(v)) end end
            end
        end
    end
    drop_numbers(settings)
    return settings
end

function store.save(settings)
    if not settings then return end
    store.tidy(settings)
    local mine = {}
    for k, v in pairs(settings) do if type(v) ~= 'function' then mine[k] = copy(v) end end
    if type(config.reload) == 'function' then
        pcall(config.reload, settings)
        mirror(settings, mine)
        assign(settings, mine)
        store.tidy(settings)
    end
    return settings:save()
end

return store
