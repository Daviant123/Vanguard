--[[
Vanguard: session stats per character (series 2 round 1, 2026-10-15). Paid automation suites (MMOMinion, the
DreamBot / TriBot / OSBot script clients) all show live per-session numbers - experience per hour, kills, deaths -
so you can see at a glance whether a camp or a party setup is worth it. Vanguard Control shows them for every
character on the Team tab.

Counted from the game's own messages (Windower 'action message' event), nothing is sent to the game:
  XP       8 / 105 / 253 "gains N experience points" (- 10 "loses N")
  Limit    371 / 372 "gains N limit points"
  CP       718 / 735 "gains N capacity points"
  Kills    a mob falls / is defeated (6, 20, 97, 113, 406, 605, 646) by someone in the party, once per mob
  Deaths   this character goes from alive to KO'd
//vg stats reset (the app's Reset button) starts a new session.
]]

local stats = {}
local S, state, h

local function now() return os.time() end

local s = { since = now(), exp = 0, lp = 0, cp = 0, kills = 0, deaths = 0 }
local seen_kill = {}       -- mob id -> time counted
local was_dead = false

function stats.reset()
    s = { since = now(), exp = 0, lp = 0, cp = 0, kills = 0, deaths = 0 }
    seen_kill = {}
end

function stats.get()
    return { since = s.since, secs = math.max(1, now() - s.since), exp = s.exp, lp = s.lp, cp = s.cp,
             kills = s.kills, deaths = s.deaths }
end

local KILL = { [6] = true, [20] = true, [97] = true, [113] = true, [406] = true, [605] = true, [646] = true }

local function party_ids()
    local ids = {}
    local p = windower.ffxi.get_party() or {}
    for _, k in ipairs({ 'p0', 'p1', 'p2', 'p3', 'p4', 'p5' }) do
        local m = p[k]
        if m and m.mob and m.mob.id then ids[m.mob.id] = true end
    end
    return ids
end

-- Windower 'action message': (actor_id, target_id, actor_index, target_index, message_id, param_1, param_2, param_3)
function stats.on_message(actor_id, target_id, message_id, p1, p2)
    local player = windower.ffxi.get_player()
    if not player then return end
    local me = player.id
    if actor_id == me and stats.chain_hook then
        -- chains (farming): 253 "EXP chain #p2", 735 "Capacity chain #p1", 372 "Limit chain #p2"; 8 / 718 / 371: no chain
        local chain = ({ [253] = tonumber(p2), [735] = tonumber(p1), [372] = tonumber(p2), [8] = 0, [718] = 0, [371] = 0 })[message_id]
        if chain then pcall(stats.chain_hook, chain) end
    end
    if actor_id == me then
        if message_id == 8 or message_id == 253 then s.exp = s.exp + (tonumber(p1) or 0)
        elseif message_id == 105 then s.exp = s.exp + (tonumber(p2) or 0)
        elseif message_id == 10 then s.exp = s.exp - (tonumber(p1) or 0)
        elseif message_id == 371 or message_id == 372 then s.lp = s.lp + (tonumber(p1) or 0)
        elseif message_id == 718 then s.cp = s.cp + (tonumber(p1) or 0)
        elseif message_id == 735 then s.cp = s.cp + (tonumber(p2) or 0)
        end
    end
    if KILL[message_id] and target_id then
        local mob = windower.ffxi.get_mob_by_id(target_id)
        local ids = party_ids()
        local by_party = ids[actor_id] or (mob and mob.claim_id and ids[mob.claim_id])
        if mob and mob.is_npc and mob.spawn_type == 16 and by_party then
            local t = seen_kill[target_id]
            if not t or now() - t > 60 then          -- one kill per mob (several messages can name it)
                seen_kill[target_id] = now()
                s.kills = s.kills + 1
                if stats.kill_hook then pcall(stats.kill_hook, mob) end   -- farming's mob report
            end
        end
    end
end

-- Every tick: count our own KOs.
function stats.tick(player)
    local dead = player.status == 2 or player.status == 3 or ((player.vitals or {}).hp == 0)
    if dead and not was_dead then s.deaths = s.deaths + 1 end
    was_dead = dead
end

function stats.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return stats
