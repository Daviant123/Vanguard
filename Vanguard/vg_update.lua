--[[
Vanguard updates from its GitHub page (user request 2026-10-15; same design as Steward's //stw update).

  //vg update            check for a newer version (and say how to get it)
  //vg update install    download the newer version into this addon folder, then //lua r vanguard
  //vg update off|on     stop / start checking when Vanguard loads

Where it looks: settings update.repo ("owner/name" on GitHub), update.path (the folder on that page, "Vanguard")
and update.branch (main). That folder holds version.txt (e.g. 0.11.0), manifest.txt (the files that make up
Vanguard, one per line) and those files. A check reads one tiny file; Windower's Lua can't fetch in the
background, so the game may hitch for a moment. Installing only ever writes the .lua files and README.md named in
manifest.txt into this addon's folder; settings (the data folder) are never touched. Nothing is installed unless
you type //vg update install. The Vanguard Control panel is a separate download on the same page.
]]

local update = { checked = false, latest = nil }
local S, log, save

update.get = function(url)                  -- blocking fetch; tests replace this
    local https = require('ssl.https')
    local ltn12 = require('ltn12')
    https.TIMEOUT = 8
    local body = {}
    local ok, code = https.request({ url = url, sink = ltn12.sink.table(body), redirect = false,
        headers = { ['user-agent'] = 'Vanguard (Windower addon)' } })
    if not ok or code ~= 200 then return nil, tostring(code) end
    return table.concat(body)
end

local function raw(file)
    local path = (S.update.path or ''):gsub('^/+', ''):gsub('/+$', '')
    return ('https://raw.githubusercontent.com/%s/%s/%s%s'):format(S.update.repo, S.update.branch or 'main',
        path ~= '' and (path .. '/') or '', file)
end

-- '0.10.2' > '0.9.9'
function update.newer(a, b)
    local function parts(v) local t = {} for n in tostring(v or ''):gmatch('%d+') do t[#t + 1] = tonumber(n) end return t end
    local x, y = parts(a), parts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

local function configured()
    return S.update and type(S.update.repo) == 'string' and S.update.repo:match('^[%w%-_.]+/[%w%-_.]+$') ~= nil
end

-- Returns the newer version string, or nil (and says so unless quiet).
function update.check(quiet)
    if not configured() then
        if not quiet then log('Updates: no GitHub page set yet (//vg update repo <owner>/<name>).') end
        return nil
    end
    local ok, text = pcall(update.get, raw('version.txt'))
    local latest = ok and text and text:match('(%d+%.%d+[%.%d]*)')
    update.checked = true
    if not latest then
        if not quiet then log('Updates: could not reach the GitHub page; try again later.') end
        return nil
    end
    update.latest = latest
    if update.newer(latest, _addon.version) then
        log(('Vanguard %s is available (you have %s). //vg update install gets it.'):format(latest, _addon.version))
        return latest
    end
    if not quiet then log(('Vanguard is up to date (%s).'):format(_addon.version)) end
    return nil
end

-- Download every file in manifest.txt, then write them all (so a failed download changes nothing).
function update.install()
    local latest = update.check(true)
    if not latest then
        if configured() and update.latest then log(('Vanguard is up to date (%s).'):format(_addon.version)) end
        if not configured() then log('Updates: no GitHub page set yet (//vg update repo <owner>/<name>).') end
        return false
    end
    local ok, manifest = pcall(update.get, raw('manifest.txt'))
    if not ok or not manifest then log('Updates: could not read the file list; nothing changed.') return false end
    local files, main = {}, false
    for line in manifest:gmatch('[^\r\n]+') do
        local name = line:gsub('^%s+', ''):gsub('%s+$', '')
        if name ~= '' then
            -- only plain Vanguard files in this folder: no paths, never the data folder
            if not (name:match('^[%w_]+%.lua$') or name == 'README.md') then
                log(('Updates: unexpected file "%s" in the list; nothing changed.'):format(name))
                return false
            end
            if name == 'Vanguard.lua' then main = true end
            files[#files + 1] = name
        end
    end
    if not main then log('Updates: the file list looks wrong; nothing changed.') return false end
    local got = {}
    for _, name in ipairs(files) do
        local ok2, text = pcall(update.get, raw(name))
        if not ok2 or not text or #text == 0 then log(('Updates: could not download %s; nothing changed.'):format(name)) return false end
        got[name] = text
    end
    local base = windower.addon_path:gsub('[/\\]$', '') .. '/'
    for _, name in ipairs(files) do
        local f = io.open(base .. name, 'wb')
        if not f then log(('Updates: could not write %s (stopped part-way; //vg update install again).'):format(name)) return false end
        f:write(got[name])
        f:close()
    end
    log(('Vanguard %s installed (%d files). Reload it now: //lua r vanguard (on each character)'):format(latest, #files))
    return true
end

function update.command(args)
    local sub = (args[1] or ''):lower()
    if sub == 'install' then update.install()
    elseif sub == 'off' or sub == 'on' then
        S.update.check = (sub == 'on')
        save()
        log(('Updates: checking when Vanguard loads is %s.'):format(sub:upper()))
    elseif sub == 'repo' and args[2] then
        S.update.repo = args[2]
        if args[3] then S.update.path = args[3] end
        save()
        log(('Updates: GitHub page set to %s%s.'):format(args[2], S.update.path ~= '' and (' (folder ' .. S.update.path .. ')') or ''))
        update.check(false)
    else update.check(false) end
end

-- Once, a little after loading (never during login).
function update.on_load()
    if not (S.update and S.update.check) or not configured() then return end
    coroutine.schedule(function() pcall(update.check, true) end, 30)
end

function update.init(settings, logger, saver)
    S, log, save = settings, logger, saver
end

return update
