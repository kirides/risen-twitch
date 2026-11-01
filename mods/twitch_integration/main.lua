-- Twitch Integration (base mod), the Risen counterpart of the Gothic II NINJA mod "TwitchIntegration" (twitch-integration.dll).
--
-- The connector program (twitch-integration-connector.exe: Twitch login, EventSub, chat, StreamElements) hosts the named pipe
-- \\.\pipe\__TwitchIntegration_Kirides_Conn and writes JSON messages, each with a 2-byte little-endian length in front:
--
--     {"type":"redemption","data":{"title":"Test Item","redeemer":"alice"}}          channel-point reward
--     {"type":"streamelements-perk","data":{"title":"...","redeemer":"alice"}}      StreamElements perk
--     {"type":"bits","data":{"bitsUsed":100,"user":"alice"}}
--     {"type":"chat","data":{"text":"#weak","sender":"alice"}}
--     {"type":"ping"}                                                             every 5 s while nothing else is sent
--
-- This mod is the CLIENT of that pipe (risen.pipe, read-only: nothing listens on the network). What a reward, perk, bits amount or chat text DOES is
-- written in custom.lua next to this file (it replaces the twitch-integration.json of the Gothic II version). Each message becomes one or more
-- actions "command arguments", and each action an event
--     REWARD_ADD | BITS_USED | CHAT   <user>   <command> [arguments...]
--
-- Events are only ever executed INSIDE a running game session: not at the main menu, not while a savegame loads, not while a menu has the world
-- paused, not while the player is dead. Events that arrive earlier wait (and expire after `max_age_s`, so a stream break does not fire a backlog).
-- The mod then offers each event to the action mods with
--     risen.emit("twitch.command", ctx)
-- where ctx = { type, user, command, args (string), argv (list), handled = false, defer = false, message = nil }. An action mod that knows
-- ctx.command sets ctx.handled = true. It may set ctx.defer = true instead ("not now": e.g. no room to spawn): the event is offered again later,
-- for `defer_s` seconds. When no action mod handles the command and it names a console command listed in `console_allow`, it runs exactly as if typed
-- into the game's console (risen.debug.console).

local cfg = risen.config({
    retry_s          = 5,       -- seconds between connection attempts while the connector is not running
    interval_s       = 0.5,     -- at most one event per interval (like the Gothic II version)
    max_age_s        = 300,     -- an event that waited longer than this outside a session is dropped (0 = never)
    defer_s          = 120,     -- how long a deferred event is offered again
    max_deferred     = 40,
    print_redemptions = true,   -- a line in the HUD's game log when an event was executed
    console_allow    = "weather,timescale",  -- console commands a mapped action may run without an action mod (comma separated, "" = none)
})

local PIPE = "__TwitchIntegration_Kirides_Conn"
local TYPES = { REWARD_ADD = true, BITS_USED = true, FOLLOW = true, CHAT = true }

local M = { in_world = false }

local pipe
local inbox = {}       -- { line, t }: received, not yet offered
local deferred = {}    -- { ev, t }
local last_run = -1e9
local stats = { received = 0, mapped = 0, unmapped = 0, executed = 0, ignored = 0, expired = 0, bad = 0 }
local chat_last = {}   -- chat text -> clock of its last use (cooldowns)

-- custom.lua: what rewards, perks, bits and chat texts do. A broken file is reported and treated as empty.
local custom = { rewards = {}, perks = {}, bits = {}, chat = {} }
do
    local ok, loaded = pcall(require, "custom")
    if ok and type(loaded) == "table" then
        for k in pairs(custom) do custom[k] = type(loaded[k]) == "table" and loaded[k] or {} end
    else
        risen.log.error("twitch: custom.lua could not be loaded: " .. tostring(loaded))
    end
end

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

-- ---- connector message -> actions (the table of custom.lua) -----------------------------------------------------------------------------------------

-- the actions of an entry: a list of strings, or { actions = {...}, cooldown_s = n }
local function actions_of(entry)
    if type(entry) ~= "table" then return nil end
    if entry.actions then return entry.actions, tonumber(entry.cooldown_s) or 0 end
    return entry, 0
end

local function upper_lookup(tbl, key)
    local want = tostring(key):upper()
    for k, v in pairs(tbl) do
        if type(k) == "string" and k:upper() == want then return v end
    end
end

-- One decoded message -> "REWARD_ADD user action" lines (the Go DLL of the Gothic II version does exactly this with its json config).
function M.translate(msg)
    local typ, d = msg.type, type(msg.data) == "table" and msg.data or {}
    local out = {}
    local function add(kind, user, entry, cooldown_key)
        local list, cooldown = actions_of(entry)
        if not list then return end
        if cooldown > 0 and cooldown_key then
            local t = now()
            if chat_last[cooldown_key] and t - chat_last[cooldown_key] < cooldown then return end
            chat_last[cooldown_key] = t
        end
        for _, a in ipairs(list) do
            if type(a) == "string" and a:match("%S") then out[#out + 1] = ("%s %s %s"):format(kind, user, a:match("^%s*(.-)%s*$")) end
        end
    end
    local user = tostring(d.redeemer or d.user or d.sender or ""):gsub("%s", "")
    if typ == "redemption" then
        add("REWARD_ADD", user, upper_lookup(custom.rewards, d.title or ""))
    elseif typ == "streamelements-perk" then
        add("REWARD_ADD", user, upper_lookup(custom.perks, d.title or ""))
    elseif typ == "bits" then
        add("BITS_USED", user, custom.bits[tonumber(d.bitsUsed) or -1])
    elseif typ == "chat" then
        add("CHAT", user, custom.chat[tostring(d.text or "")], "chat:" .. tostring(d.text))
    end
    return out
end

-- Is it fine to run an event right now? (the session gate)
function M.ready()
    if not M.in_world then return false end
    local p = risen.entity.player()
    if not p or p:is_dead() then return false end
    return true
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
        risen.log.info(("twitch: %s %s %s %s"):format(ev.type, ev.user, ev.command, ev.args))
    elseif result == "defer" then
        if from_deferred then
            deferred[#deferred + 1] = entry
        elseif #deferred < cfg.max_deferred then
            deferred[#deferred + 1] = { ev = ev, t = now() }
        else
            risen.log.warn("twitch: too many deferred events, dropped " .. ev.command)
        end
    else
        stats.ignored = stats.ignored + 1
        risen.log.warn(("twitch: nobody handles '%s' (from %s)"):format(ev.command, ev.user))
    end
end

local function enqueue(line, t)
    if #inbox < 200 then inbox[#inbox + 1] = { line = line, t = t } end
end

-- one raw pipe message (JSON text) -> inbox entries
function M.on_message(text)
    local msg = risen.json.decode(text)
    if type(msg) ~= "table" or type(msg.type) ~= "string" then
        stats.bad = stats.bad + 1
        risen.log.warn("twitch: bad message: " .. text:sub(1, 80))
        return
    end
    if msg.type == "ping" then return end
    stats.received = stats.received + 1
    local lines = M.translate(msg)
    if #lines == 0 then
        stats.unmapped = stats.unmapped + 1
        risen.log.debug(("twitch: nothing mapped for %s %s"):format(msg.type, text:sub(1, 80)))
        return
    end
    local t = now()
    for _, line in ipairs(lines) do
        stats.mapped = stats.mapped + 1
        enqueue(line, t)
    end
end

-- Takes what the pipe received. Runs at every frame of the application (also in menus): it only moves messages, it executes nothing.
local last_poll = -1e9
local function collect()
    if not pipe then return end
    local t = now()
    if t - last_poll < 0.25 then return end
    last_poll = t
    for _, text in ipairs(pipe:poll(50)) do M.on_message(text) end
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
pipe, why = risen.pipe.open(PIPE, { retry = cfg.retry_s, framing = "u16" })
if not pipe then
    risen.log.error("twitch: cannot open the pipe: " .. tostring(why))
end

-- Test hooks: feed a raw line "TYPE user command args" or a connector message (JSON text) as if the connector had sent it; read the counters;
-- close or open the session gate by hand.
risen.on("twitch.inject", function(line) enqueue(line, now()) end)
risen.on("twitch.inject_message", function(text) M.on_message(text) end)
risen.on("twitch.gate", function(open) M.in_world = open and true or false end)
risen.on("twitch.status", function(out)
    out.in_world = M.in_world
    out.connected = pipe and pipe:connected() or false
    out.inbox = #inbox
    out.deferred = #deferred
    for k, v in pairs(stats) do out[k] = v end
end)
