--[[
Vanguard: characters sharing what they do, and sending commands (round 7, 2026-10-15; after HealBot's
IPC debuff sharing and the Send addon from Byrth's dualboxing guide).

  Shared enfeebles   When one character casts an enfeeble on a mob ("vg_debuff <mob> <spell> cast") the others
                     wait; when it lands ("landed") they never cast it on that mob; if it's resisted they may try.
  Healer teamwork    A healer starting a cure tells the others ("vg_cure <healer> <target> <seconds>"); they
                     leave that member to it for the cast time, unless the member drops under share.emergency
                     (35%). A Curaga covers everyone.
  //vg send <command>          on every other character   (e.g. //vg send /ma "Haste" CharA, //vg send warp)
  //vg sendall <command>       on every character, this one too
  //vg sendto <name> <command> on one character
                     A command starting with / is typed into the game (input /...); anything else is a Windower
                     command (e.g. another addon's command).

All over Windower's local IPC; the commands themselves are normal game / Windower commands.
]]

local share = {}
local S, state, h

local function clock() return os.clock() end

------------------------------------------------------------------------
-- Enfeebles
------------------------------------------------------------------------
function share.debuff(mob_id, spell, what)
    windower.send_ipc_message(('vg_debuff %d %s %s'):format(mob_id, spell, what))
end

function share.on_debuff(mob_id, spell, what)
    state.debuffs[mob_id] = state.debuffs[mob_id] or {}
    local r = state.debuffs[mob_id][spell] or { tries = 0, landed = false }
    state.debuffs[mob_id][spell] = r
    if what == 'landed' then r.landed = true
    elseif what == 'cast' then r.other_until = clock() + 8
    elseif what == 'resisted' then r.other_until = nil end
end

-- Someone else is casting it right now / it already landed.
function share.debuff_blocked(r) return r.landed or (r.other_until and clock() < r.other_until) end

------------------------------------------------------------------------
-- Cures
------------------------------------------------------------------------
function share.cure(player, target, seconds)
    windower.send_ipc_message(('vg_cure %s %s %d'):format(player.name, target, math.ceil(seconds)))
end

function share.on_cure(player, from, target, seconds)
    if from:lower() == player.name:lower() then return end
    state.cured = state.cured or {}
    state.cured[target:lower()] = clock() + (tonumber(seconds) or 3) + 1
end

-- Another healer is already curing this member (or the whole party with Curaga)?
function share.being_cured(member)
    local c = state.cured or {}
    if member.hpp < (tonumber(S.share.emergency) or 35) then return false end
    local t1, t2 = c[member.name:lower()], c['*']
    return (t1 and clock() < t1) or (t2 and clock() < t2) or false
end

------------------------------------------------------------------------
-- Sending commands to the other characters
------------------------------------------------------------------------
local function run(cmd)
    if cmd:sub(1, 1) == '/' then windower.send_command('input ' .. cmd) else windower.send_command(cmd) end
end

function share.send(player, who, cmd)
    if not cmd or cmd == '' then h.log('Usage: //vg send <command>   //vg sendall <command>   //vg sendto <name> <command>') return end
    windower.send_ipc_message(('vg_send %s %s %s'):format(player.name, who, cmd))
    if who == '**' then run(cmd) end
    h.log(('Sent to %s: %s'):format(who == '*' and 'the others' or (who == '**' and 'everyone') or who, cmd))
end

function share.on_send(player, from, who, cmd)
    if from:lower() == player.name:lower() then return end
    if who ~= '*' and who ~= '**' and who:lower() ~= player.name:lower() then return end
    run(cmd)
end

function share.init(settings, runtime_state, helpers)
    S, state, h = settings, runtime_state, helpers
end

return share
