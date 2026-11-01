-- Twitch Integration (base mod), the Risen counterpart of the Gothic II NINJA mod "TwitchIntegration".
--
-- A Twitch bridge program (it owns the Twitch login, the channel-point rewards and the mapping reward -> command) hosts the named pipe
-- \\.\pipe\__TwitchIntegration_Kirides_Conn and writes one line per event:
--
--     REWARD_ADD <user> <command> [arguments...]        a channel-point redemption or StreamElements perk
--     BITS_USED  <user> <command> [arguments...]
--     FOLLOW     <user> <command> [arguments...]
--     CHAT       <user> <command> [arguments...]        a chat command
--
-- This mod is the CLIENT of that pipe (risen.pipe: nothing listens on the network). It only ever executes an event INSIDE a running game session:
-- not at the main menu, not while a savegame loads, not while a menu has the world paused, not while the player is dead. Events that arrive earlier
-- wait (and expire after `max_age_s`, so a stream break does not fire a backlog). The mod then offers each event to the action mods with
--     risen.emit("twitch.command", ctx)
-- where ctx = { type, user, command, args (string), argv (list), handled = false, defer = false, message = nil }. An action mod that knows
-- ctx.command sets ctx.handled = true. It may set ctx.defer = true instead ("not now": e.g. no room to spawn): the event is offered again later,
-- for `defer_s` seconds. When no action mod handles the command and it names a console command listed in `console_allow`, it runs exactly as if typed
-- into the game's console (risen.debug.console).

local cfg = risen.config({
    retry_s          = 5,       -- seconds between connection attempts while the bridge is not running
    interval_s       = 0.5,     -- at most one event per interval (like the Gothic II version)
    max_age_s        = 300,     -- an event that waited longer than this outside a session is dropped (0 = never)
    defer_s          = 120,     -- how long a deferred event is offered again
    max_deferred     = 40,
    print_redemptions = true,   -- a line in the HUD's game log when an event was executed
    console_allow    = "weather,timescale",  -- console commands a bridge command may run without an action mod (comma separated, "" = none)
    ack              = false,   -- answer every event with "ACK <type> <user> <command> ok|deferred|ignored" on the pipe
})

local PIPE = "__TwitchIntegration_Kirides_Conn"
local TYPES = { REWARD_ADD = true, BITS_USED = true, FOLLOW = true, CHAT = true }

local M = { in_world = false }

local pipe
local inbox = {}       -- { line, t }: received, not yet offered
local deferred = {}    -- { ev, t_first }
local last_run = -1e9
local stats = { received = 0, executed = 0, ignored = 0, expired = 0, bad = 0 }

local allowed_console = {}
for name in tostring(cfg.console_allow):gmatch("[^,%s]+") do allowed_console[name:lower()] = true end

local function now() return risen.clock() end

local function split(s)
    local t = {}
    for w in s:gmatch("%S+") do t[#t + 1] = w end
    return t
end

-- "TYPE user command rest..." -> event table, or nil, reason
function M.parse(line)
    local typ, user, command, rest = line:match("^(%S+)%s+(%S+)%s+(%S+)%s*(.-)%s*$")
    if not typ then return nil, "expected 'TYPE user command [args]'" end
    if not TYPES[typ] then return nil, "unknown event type '" .. typ:sub(1, 20) .. "'" end
    return { type = typ, user = user, command = command, args = rest, argv = split(rest) }
end

-- Is it fine to run an event right now? (the session gate)
function M.ready()
    if not M.in_world then return false end
    local p = risen.entity.player()
    if not p or p:is_dead() then return false end
    return true
end

local function ack(ev, what)
    if cfg.ack and pipe and pipe:connected() then
        pipe:send(("ACK %s %s %s %s"):format(ev.type, ev.user, ev.command, what))
    end
end

local function announce(ev)
    if not cfg.print_redemptions then return end
    local text = ev.message or (ev.user .. " -> " .. ev.command .. (ev.args ~= "" and (" " .. ev.args) or ""))
    risen.hud.log(text, 1)
end

-- Offers one event to the action mods. Returns "done" | "defer" | "ignored".
local function execute(ev)
    local ctx = { type = ev.type, user = ev.user, command = ev.command, args = ev.args, argv = ev.argv, handled = false, defer = false }
    risen.emit("twitch.command", ctx)
    if ctx.defer then return "defer" end
    if ctx.handled then
        ev.message = ctx.message
        announce(ev)
        return "done"
    end
    local lower = ev.command:lower()
    if allowed_console[lower] then
        local ok, msg = risen.debug.console(ev.command, (unpack or table.unpack)(ev.argv))
        if ok ~= nil then
            announce(ev)
            return "done"
        end
        risen.log.warn(("twitch: console command '%s' failed: %s"):format(ev.command, tostring(msg)))
        return "ignored"
    end
    return "ignored"
end

local function handle_result(ev, result, from_deferred, entry)
    if result == "done" then
        stats.executed = stats.executed + 1
        ack(ev, "ok")
        risen.log.info(("twitch: %s %s %s %s"):format(ev.type, ev.user, ev.command, ev.args))
    elseif result == "defer" then
        if from_deferred then
            deferred[#deferred + 1] = entry
        elseif #deferred < cfg.max_deferred then
            deferred[#deferred + 1] = { ev = ev, t = now() }
            ack(ev, "deferred")
        else
            risen.log.warn("twitch: too many deferred events, dropped " .. ev.command)
        end
    else
        stats.ignored = stats.ignored + 1
        ack(ev, "ignored")
        risen.log.warn(("twitch: nobody handles '%s' (from %s)"):format(ev.command, ev.user))
    end
end

-- Takes what the pipe received. Runs at every frame of the application (also in menus): it only moves lines, it executes nothing.
local last_poll = -1e9
local function collect()
    if not pipe then return end
    local t = now()
    if t - last_poll < 0.25 then return end
    last_poll = t
    for _, line in ipairs(pipe:poll(50)) do
        stats.received = stats.received + 1
        if #inbox < 200 then inbox[#inbox + 1] = { line = line, t = t } end
    end
    -- expire what waited too long (outside a session nothing is consumed)
    if cfg.max_age_s > 0 then
        while inbox[1] and t - inbox[1].t > cfg.max_age_s do
            table.remove(inbox, 1)
            stats.expired = stats.expired + 1
        end
    end
end

-- One step: the session gate, then one event (a due deferred one first).
function M.step()
    local t = now()
    if t - last_run < cfg.interval_s then return false end
    if not M.ready() then return false end
    last_run = t

    -- deferred events: drop the expired, retry the oldest
    for i = #deferred, 1, -1 do
        if t - deferred[i].t > cfg.defer_s then
            table.remove(deferred, i)
            stats.expired = stats.expired + 1
        end
    end
    if deferred[1] then
        local entry = table.remove(deferred, 1)
        local res = execute(entry.ev)
        if res == "defer" then deferred[#deferred + 1] = entry else handle_result(entry.ev, res, true, entry) end
        return true
    end

    local item = table.remove(inbox, 1)
    if not item then return false end
    local ev, why = M.parse(item.line)
    if not ev then
        stats.bad = stats.bad + 1
        risen.log.warn(("twitch: bad line '%s': %s"):format(item.line:sub(1, 80), why))
        return true
    end
    handle_result(ev, execute(ev), false)
    return true
end

-- ---- the session gate: events are only executed between world.ready and the end of the session ------------------------------------------------------

risen.on("world.ready", function() M.in_world = true end)
risen.on("session.start", function() M.in_world = false end)
risen.on("session.stop", function() M.in_world = false end)
risen.on("load.before", function() M.in_world = false end)

risen.on("ui.frame", collect)
risen.on("tick", function() M.step() end)

-- ---- the pipe ------------------------------------------------------------------------------------------------------------------------------------

local why
pipe, why = risen.pipe.open(PIPE, { retry = cfg.retry_s })
if not pipe then
    risen.log.error("twitch: cannot open the pipe: " .. tostring(why))
end

-- A test (or another mod) can feed a line as if the bridge had sent it; and read the counters.
risen.on("twitch.inject", function(line) inbox[#inbox + 1] = { line = line, t = now() } end)
risen.on("twitch.status", function(out)
    out.in_world = M.in_world
    out.connected = pipe and pipe:connected() or false
    out.inbox = #inbox
    out.deferred = #deferred
    for k, v in pairs(stats) do out[k] = v end
end)
-- test hook: closes (or opens) the session gate by hand
risen.on("twitch.gate", function(open) M.in_world = open and true or false end)
