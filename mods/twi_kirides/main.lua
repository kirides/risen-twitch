-- TWI_* actions for the Twitch Integration base mod (event `twitch.command`). Every action does what the player could do with the game's console or a
-- cheat: spawn, give gold, change hit points, set the clock, change the game speed.
--
--   A = function(ctx, argv, player) return true | false, "why" end
-- true = done (the base mod prints it). false = "not now" -> the base mod offers the event again later (e.g. no room to spawn). The command names are
-- not case sensitive.

local R = risen
local actions = {}
local timed = {}          -- { at = clock seconds, undo = function }, run from the tick handler

local function num(s, default)
    local n = tonumber(s)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- numeric gESkill of a friendly skill name ("Strength", "Sneak")
local function skill_id(name)
    local enum = R.balance.skill_enum(name)
    return enum and R.item.skill_id(enum)
end

local function rint(lo, hi) return R.random.int(lo, hi) end

local function later(seconds, undo) timed[#timed + 1] = { at = R.clock() + seconds, undo = undo } end

-- ---- spawning -------------------------------------------------------------------------------------------------------------------------------------

-- A spot 5..9 m from the player, snapped to the walkable ground where the engine knows one.
local function spot_near(player)
    local px, py, pz = player:position()
    if not px then return nil end
    for _ = 1, 8 do
        local a = R.random.float(0, 2 * math.pi)
        local d = R.random.float(500, 900)
        local x, z = px + math.cos(a) * d, pz + math.sin(a) * d
        local p = R.world.nav_point(x, py, z, 300)
        if p then return p[1], p[2], p[3] end
    end
    return px + 400, py, pz
end

-- who asked for the action being run (set by the dispatcher): spawned NPCs and monsters carry the name in their label
local current_user = ""
local spawn_counter = 0

-- Every spawned NPC gets a unique entity name and the label "<who>'s <Template>" (the engine shows `FO_<entity name>` when the player looks at it):
-- `label_for` overrides the text (TWI_SpawnNpcNamed). The label is a runtime text, so it is gone after a savegame is loaded.
local function spawn_many(player, template, n, opts, label_for)
    if not R.template.exists(template) then return 0, "unknown template '" .. template .. "'" end
    local who = label_for or current_user
    local made = 0
    for _ = 1, n do
        local x, y, z = spot_near(player)
        if not x then break end
        local o = {}
        for k, v in pairs(opts or {}) do o[k] = v end
        if who ~= "" then
            spawn_counter = spawn_counter + 1
            o.name = ("TWI_%d_%s"):format(spawn_counter, (who:gsub("[^%w_]", "")):sub(1, 20))
            R.loc.set("FO_" .. o.name, label_for and who or (who .. "'s " .. template))
        end
        if R.npc.spawn(template, x, y, z, o) then made = made + 1 end
    end
    return made
end

local function amount(s, default, max) return clamp(math.floor(num(s, default)), 1, max or 10) end

-- Monster pools by chapter (names from docs/TEMPLATES.md "Monster/Kapitel N"). `limit` keeps a stream from spawning a Titan in chapter 1.
local POOLS = {
    [1] = { "Wolf", "Wolf_Black", "Boar", "Stingrat", "SwampMummy", "Vulture" },
    [2] = { "Ghul", "GiantBug", "Gyrger", "LizardScout", "Rotworm", "Skeleton", "Thundertail" },
    [3] = { "LizardPriest", "LizardWarrior", "Skeleton", "Gyrger" },
    [4] = { "AshBeast", "GiantScorpion", "LizardWarrior_Elite", "LizardWarrior_Undead", "LizardPriest_Undead", "Ogre" },
}
local ALL = { "Wolf", "Boar", "Ghul", "GiantBug", "Gyrger", "LizardScout", "Rotworm", "Skeleton", "Thundertail", "LizardPriest", "LizardWarrior",
              "AshBeast", "GiantScorpion", "LizardWarrior_Elite", "Ogre", "Titan", "Inferno" }
local LIZARDS = { [1] = { "LizardScout" }, [2] = { "LizardScout" }, [3] = { "LizardScout", "LizardWarrior", "LizardPriest" }, [4] = { "LizardWarrior_Elite", "LizardWarrior_Undead", "LizardPriest_Undead" } }

local function chapter() return clamp(R.quest.chapter() or 1, 1, 4) end

local function spawn_from(pool, player, n)
    local made = 0
    for _ = 1, n do
        local tpl = R.random.choice(pool)
        made = made + (spawn_many(player, tpl, 1))
    end
    return made > 0
end

actions.twi_spawnenemy = function(_, argv, p)
    if not argv[1] then return false, "usage: TWI_SpawnEnemy <template> [amount]" end
    local made, why = spawn_many(p, argv[1], amount(argv[2], 1))
    return made > 0, why
end
actions.twi_spawnnpc = function(_, argv, p)
    if not argv[1] then return false, "usage: TWI_SpawnNpc <template> [amount]" end
    local made, why = spawn_many(p, argv[1], amount(argv[2], 1), { peaceful = true })
    return made > 0, why
end
actions.twi_spawnnpcimmortal = function(_, argv, p)
    if not argv[1] then return false, "usage: TWI_SpawnNpcImmortal <template> [amount]" end
    local made, why = spawn_many(p, argv[1], amount(argv[2], 1), { peaceful = true, hp_max = 100000 })
    return made > 0, why
end
actions.twi_spawnnpcnamed = function(_, argv, p)
    if #argv < 2 then return false, "usage: TWI_SpawnNpcNamed <name> <template> [amount]" end
    local made, why = spawn_many(p, argv[2], amount(argv[3], 1), { peaceful = true }, argv[1])
    return made > 0, why
end
local function one_of(argv) return #argv > 0 and R.random.choice(argv) or nil end
actions.twi_spawnnpconeof = function(_, argv, p)
    local t = one_of(argv)
    if not t then return false, "usage: TWI_SpawnNpcOneOf <template...>" end
    return spawn_many(p, t, 1, { peaceful = true }) > 0
end
actions.twi_spawnenemyoneof = function(_, argv, p)
    local t = one_of(argv)
    if not t then return false, "usage: TWI_SpawnEnemyOneOf <template...>" end
    return spawn_many(p, t, 1) > 0
end
actions.twi_spawnrandommonster = function(_, argv, p) return spawn_from(POOLS[chapter()], p, amount(argv[1], 1)) end
actions.twi_spawnrandommonsternolimit = function(_, argv, p) return spawn_from(ALL, p, amount(argv[1], 1)) end
actions.twi_raid_beasts = function(_, argv, p) return spawn_from(POOLS[chapter()], p, amount(argv[1], rint(1, 3), 12)) end
actions.twi_raid_lizards = function(_, argv, p) return spawn_from(LIZARDS[chapter()], p, amount(argv[1], rint(1, 3), 12)) end

-- ---- gold, items ----------------------------------------------------------------------------------------------------------------------------------

-- TWI_Money 100 gives gold, TWI_Money -50 takes it (never more than the player has).
actions.twi_money = function(_, argv, p)
    local n = math.floor(num(argv[1], 0))
    if n == 0 then return false, "usage: TWI_Money <amount>" end
    if n > 0 then return R.item.give(p, "It_Gold", clamp(n, 1, 100000)) >= 0 end
    local have = math.floor(R.item.money(p) or 0)
    local take = math.min(-n, have)
    if take > 0 then R.item.take(p, "It_Gold", take) end
    return true
end

local ITEM_GROUPS = { "Items/Potions", "Items/Food", "Items/Plants", "Items/Scrolls", "Items/Weapons_Swords", "Items/Weapons_Axes", "Items/Valueable", "Items/Minerals", "Items/Rings", "Items/Amulets" }
actions.twi_spawnitemrandom = function(_, _, p)
    local list = R.template.list(R.random.choice(ITEM_GROUPS))
    if #list == 0 then return false end
    return R.item.give(p, R.random.choice(list), 1) >= 0
end

-- ---- health, mana, attributes ---------------------------------------------------------------------------------------------------------------------

actions.twi_fullheal = function(_, _, p)
    p:set_hp(p:hp_max()); p:set_mana(p:mana_max())
    return true
end
actions.twi_sethp = function(_, argv, p)
    local n = math.floor(num(argv[1], 1))
    return p:set_hp(clamp(n, 1, p:hp_max()))
end
actions.twi_setmana = function(_, argv, p)
    local n = math.floor(num(argv[1], 0))
    return p:set_mana(clamp(n, 0, p:mana_max()))
end
actions.twi_randomhp_pct = function(_, argv, p)
    local lo, hi = clamp(num(argv[1], 1), 1, 100), clamp(num(argv[2], 25), 1, 100)
    if lo > hi then lo, hi = hi, lo end
    return p:set_hp(math.max(1, math.floor(p:hp_max() * rint(lo, hi) / 100)))
end
-- TWI_SetHP_Timed <amount> <seconds>: the hit points are held at `amount` (not above) for the time
local function timed_clamp(getter_set, seconds)
    local untill = R.clock() + seconds
    local h
    h = R.on("tick", function()
        if R.clock() > untill then R.off(h) return end
        getter_set()
    end)
end
actions.twi_sethp_timed = function(_, argv, p)
    local n, s = math.floor(num(argv[1], 1)), clamp(num(argv[2], 5), 1, 120)
    timed_clamp(function() local q = R.entity.player(); if q and q:hp() > n then q:set_hp(math.max(1, n)) end end, s)
    return true
end
actions.twi_setmana_timed = function(_, argv, p)
    local n, s = math.floor(num(argv[1], 0)), clamp(num(argv[2], 5), 1, 120)
    timed_clamp(function() local q = R.entity.player(); if q and q:mana() > n then q:set_mana(math.max(0, n)) end end, s)
    return true
end
-- TWI_RandomStatBonus <STR|DEX|HP|MANA> <min> <max> <low> <high>: changes the attribute by a random value in low..high, the result stays in min..max
actions.twi_randomstatbonus = function(_, argv, p)
    local atr = (argv[1] or ""):upper()
    local lo, hi = math.floor(num(argv[2], 1)), math.floor(num(argv[3], 250))
    local d_lo, d_hi = math.floor(num(argv[4], -10)), math.floor(num(argv[5], 10))
    if d_lo > d_hi then d_lo, d_hi = d_hi, d_lo end
    local delta = rint(d_lo, d_hi)
    if atr == "HP" then
        local cur = p:hp_max(); return p:add_hp_max(clamp(cur + delta, lo, hi) - cur)
    elseif atr == "MANA" then
        local cur = p:mana_max(); return p:add_mana_max(clamp(cur + delta, lo, hi) - cur)
    end
    local skill = ({ STR = "Strength", DEX = "Dexterity", INT = "Intelligence" })[atr]
    if not skill then return false, "usage: TWI_RandomStatBonus <STR|DEX|INT|HP|MANA> <min> <max> <low> <high>" end
    local id = skill_id(skill)
    local base = id and R.npc.skill_raw(p, id)
    if not base then return false, "cannot read " .. skill end
    return R.npc.set_skill_base(p, id, clamp(base + delta, lo, hi)) ~= nil
end

-- ---- teleport, equipment, talents ------------------------------------------------------------------------------------------------------------------

-- TWI_RandomWaypoint: onto a random freepoint of the world (the game's own ~170 guard points, camp fires, ... : places the navigation mesh knows)
actions.twi_randomwaypoint = function(_, _, p)
    local pts = R.world.points({ limit = 500 })
    local fps = {}
    for _, pt in ipairs(pts or {}) do
        if pt.kind == "freepoint" then fps[#fps + 1] = pt end
    end
    if #fps == 0 then return false end
    local pt = R.random.choice(fps)
    return p:teleport(pt.entity) == true
end

local function prop(item, set, name)
    local ok, v = pcall(item.get_property, item, set, name)
    return ok and v or nil
end

-- TWI_Weakest_Weapon: wields the carried melee/ranged weapon with the lowest damage (arrows and bolts are ammunition, not weapons)
actions.twi_weakest_weapon = function(_, _, p)
    local best, best_dmg
    for i = 0, (p:stack_count() or 0) - 1 do
        local it = p:stack_item(i)
        if it then
            local cat = tostring(prop(it, "gCItem_PS", "Category") or "")
            local use = tostring(prop(it, "gCItem_PS", "UseType") or "")
            if cat:find("Weapon", 1, true) and not use:find("Arrow", 1, true) and not use:find("Bolt", 1, true) and not use:find("None", 1, true) then
                local dmg = tonumber(prop(it, "gCDamage_PS", "DamageAmount")) or 0
                if not best_dmg or dmg < best_dmg then best, best_dmg = it:name(), dmg end
            end
        end
    end
    if not best then return false, "the player carries no weapon" end
    return R.item.equip(p, best) == true
end

-- TWI_RandomArmor: a random body armor the player can wear (protection above 0, no women's dresses, ghosts or story costumes)
local armor_pool
local function armors()
    if armor_pool then return armor_pool end
    armor_pool = {}
    for _, name in ipairs(R.template.list("Items/Armor")) do
        if not name:find("Woman") and not name:find("Ghost") and not name:find("Intro") and not name:find("Landl") and not name:find("Titanlord") then
            local mods = R.item.modifiers(name)
            local prot = 0
            for _, m in ipairs(mods or {}) do
                if tostring(m.skill or ""):find("Prot", 1, true) then prot = prot + (tonumber(m.amount) or 0) end
            end
            if prot > 0 then armor_pool[#armor_pool + 1] = name end
        end
    end
    return armor_pool
end
actions.twi_randomarmor = function(_, _, p)
    local pool = armors()
    if #pool == 0 then return false, "no armor templates found" end
    local usable = {}
    for _, name in ipairs(pool) do
        if R.item.can_use(p, name) then usable[#usable + 1] = name end
    end
    local pick = R.random.choice(#usable > 0 and usable or pool)
    if R.item.give(p, pick, 1) < 0 then return false end
    R.item.equip(p, pick)
    return true, nil, pick
end

local TALENTS = { "Acrobat", "Pickpocket", "Lockpick", "Sneak", "Mining", "Smith", "Alchemy", "Trophy", "Scribe" }

-- sets one talent to a random value between its current base and its maximum (or 1 when the engine reports no maximum)
local function randomize_talent(p, name)
    local id = skill_id(name)
    if not id then return false end
    local base, _, _, _, max = R.npc.skill_raw(p, id)
    if not base then return false end
    local top = (max and max > 0) and max or math.max(base, 3)
    return R.npc.set_skill_base(p, id, rint(0, top)) ~= nil
end
actions.twi_randomtalent = function(_, _, p) return randomize_talent(p, R.random.choice(TALENTS)) end
actions.twi_randomtalents = function(_, _, p)
    local any = false
    for _, name in ipairs(TALENTS) do any = randomize_talent(p, name) or any end
    return any
end

-- ---- world: time, weather, speed ------------------------------------------------------------------------------------------------------------------

actions.twi_time = function(_, argv)
    local h = math.floor(num(argv[1], -1))
    if h < 0 or h > 23 then return false, "usage: TWI_Time <0..23>" end
    return R.world.set_time(h, 0)
end
actions.twi_weather = function(_, argv)
    if not argv[1] then return false, "usage: TWI_Weather <state>" end
    return R.world.set_weather(argv[1]) == true
end

local speed_until
local function set_speed(scale, seconds)
    speed_until = R.clock() + seconds
    R.debug.time_scale(scale)
    later(seconds, function()
        if speed_until and R.clock() >= speed_until - 0.01 then R.debug.time_scale(1); speed_until = nil end
    end)
    return true
end
actions.twi_southpark = function(_, argv) return set_speed(2, clamp(num(argv[1], 10), 1, 300)) end     -- faster
actions.twi_slowdown = function(_, argv) return set_speed(0.4, clamp(num(argv[1], 10), 1, 300)) end    -- slower

-- ---- dispatch -------------------------------------------------------------------------------------------------------------------------------------

R.on("twitch.command", function(ctx)
    local fn = actions[ctx.command:lower()]
    if not fn then return end
    local player = R.entity.player()
    if not player then ctx.defer = true return end
    current_user = ctx.user or ""
    local ok, res, why, msg = pcall(fn, ctx, ctx.argv, player)
    current_user = ""
    if not ok then
        R.log.error(("twi: %s failed: %s"):format(ctx.command, tostring(res)))
        ctx.handled = true     -- a broken action must not come back again and again
        return
    end
    if res then
        ctx.handled = true
        if msg then ctx.message = ctx.user .. ": " .. ctx.command .. " " .. msg end
    elseif why then
        R.log.warn(("twi: %s: %s"):format(ctx.command, why))
        ctx.handled = true     -- bad arguments: retrying will not help
    else
        ctx.defer = true       -- "not now"
    end
end)

R.on("tick", function()
    if #timed == 0 then return end
    local t = R.clock()
    for i = #timed, 1, -1 do
        if t >= timed[i].at then
            local u = timed[i].undo
            table.remove(timed, i)
            u()
        end
    end
end)

-- a new game or a load starts at normal speed
R.on("session.start", function()
    if speed_until then speed_until = nil; R.debug.time_scale(1) end
end)
