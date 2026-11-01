---@diagnostic disable: need-check-nil, undefined-field, param-type-mismatch, undefined-global
-- Scenario `twitch` (test-run.ps1 -ModPath <risen-twitch>\mods -Mods twitch_integration,twi_kirides,twitch_test -Scenario twitch -WaitForResult):
-- tools/fake_bridge.py hosts the pipe and sends "REWARD_ADD early TWI_Money 123" the moment the game connects (normally at the main menu).
local T = risen.test
if not T.is_active() then return end

T.plan {
    "pipe connected", "early line was not executed outside a session", "world ready", "early line executed in the session",
    "TWI_Money gives gold", "TWI_Money takes gold", "TWI_SetHP", "TWI_Time", "TWI_SpawnEnemy", "TWI_SpawnRandomMonster",
    "unknown command is ignored", "bad arguments do not come back", "unspawnable template",
    "console fallback (weather)", "TWI_RandomWaypoint", "TWI_Weakest_Weapon", "TWI_RandomArmor", "TWI_RandomTalent", "TWI_RandomTalents", "TWI_RandomStatBonus STR", "bad line is counted", "gate closes with the session",
}

-- the gold at world.ready, read by a handler that runs before the base mod's tick can execute anything
local gold_at_ready
risen.on("world.ready", function()
    local pl = risen.entity.player()
    gold_at_ready = pl and risen.item.money(pl)
end, 100)

local equipped = {}
risen.on("item.equipped", function(owner, template) equipped[#equipped + 1] = template end)

local function status()
    local out = {}
    risen.emit("twitch.status", out)
    return out
end

local function inject(line) risen.emit("twitch.inject", line) end

local function processed() local s = status(); return s.executed + s.ignored + s.bad end

-- feeds a line and waits until the base mod has consumed it (executed, ignored or counted as bad)
local function run_and_wait(line)
    local before = processed()
    inject(line)
    T.wait_until(function() return processed() > before end, 20, line)
end

T.run(function()
    T.wait_until(function() return status().connected end, 150, "the bridge connected")
    T.expect("pipe connected", status().connected)

    local early = status()
    if not early.in_world then
        T.expect("early line was not executed outside a session", early.executed == 0, "executed=" .. tostring(early.executed))
    else
        T.expect("early line was not executed outside a session", true, "game was already running (not checked)")
    end

    T.wait_event("world.ready", 200)
    T.expect("world ready", status().in_world)
    local p = risen.entity.player()
    local gold0 = gold_at_ready
    T.wait_until(function() return status().executed >= 1 end, 30, "early line executed")
    T.expect("early line executed in the session", risen.item.money(p) == gold0 + 123, ("%s -> %s"):format(gold0, risen.item.money(p)))

    local g = risen.item.money(p)
    run_and_wait("CHAT bob TWI_Money -50")
    T.expect("TWI_Money takes gold", risen.item.money(p) == g - 50, tostring(risen.item.money(p)))
    g = risen.item.money(p)
    run_and_wait("REWARD_ADD carol twi_money 10")
    T.expect("TWI_Money gives gold", risen.item.money(p) == g + 10)

    run_and_wait("CHAT bob TWI_SetHP 7")
    T.expect("TWI_SetHP", p:hp() == 7, tostring(p:hp()))
    run_and_wait("CHAT bob TWI_FullHeal")

    run_and_wait("CHAT bob TWI_Time 21")
    local h = risen.world.time()
    T.expect("TWI_Time", h == 21, tostring(h))

    local n0 = #risen.entity.npcs(p, 3000)
    run_and_wait("CHAT bob TWI_SpawnEnemy Wolf 2")
    T.wait_until(function() return #risen.entity.npcs(p, 3000) >= n0 + 2 end, 10, "two wolves")
    T.expect("TWI_SpawnEnemy", #risen.entity.npcs(p, 3000) >= n0 + 2, ("%d -> %d"):format(n0, #risen.entity.npcs(p, 3000)))
    n0 = #risen.entity.npcs(p, 3000)
    run_and_wait("CHAT bob TWI_SpawnRandomMonster 1")
    T.expect("TWI_SpawnRandomMonster", #risen.entity.npcs(p, 3000) >= n0 + 1)

    local ig = status().ignored
    run_and_wait("CHAT bob NoSuchThing 1")
    T.expect("unknown command is ignored", status().ignored == ig + 1)
    run_and_wait("CHAT bob TWI_Time banana")
    T.expect("bad arguments do not come back", status().deferred == 0)
    run_and_wait("CHAT bob TWI_SpawnEnemy NoSuchTemplate_xyz 1")
    T.expect("unspawnable template", status().deferred == 0)

    local bad = status().bad
    run_and_wait("garbage")
    T.expect("bad line is counted", status().bad == bad + 1)

    local ex = status().executed
    run_and_wait("CHAT bob weather Foggy_Rain")
    T.expect("console fallback (weather)", status().executed == ex + 1)

    -- equipment, talents, teleport
    local x0, y0, z0 = p:position()
    run_and_wait("CHAT bob TWI_RandomWaypoint")
    local x1, y1, z1 = p:position()
    T.expect("TWI_RandomWaypoint", math.abs(x1 - x0) + math.abs(z1 - z0) > 50, ("%.0f,%.0f -> %.0f,%.0f"):format(x0, z0, x1, z1))

    risen.item.give(p, "It_1H_Sword", 1)
    risen.item.give(p, "It_Axe_Waraxe", 1)
    equipped = {}
    run_and_wait("CHAT bob TWI_Weakest_Weapon")
    T.wait_until(function() return #equipped > 0 end, 10, "a weapon was equipped")
    local w = equipped[#equipped]
    local dmg = tonumber(risen.template.get(w) and risen.template.get(w):get_property("gCDamage_PS", "DamageAmount")) or 999
    T.expect("TWI_Weakest_Weapon", w ~= "It_Axe_Waraxe" and dmg <= 15, ("%s damage %s"):format(w, dmg))

    local before = risen.item.count(p, "It_Armor_Guard")
    run_and_wait("CHAT bob TWI_RandomArmor")
    local armors_now = 0
    for i = 0, p:stack_count() - 1 do
        local it = p:stack_item(i)
        if it and tostring(it:name()):find("^It_Armor") then armors_now = armors_now + 1 end
    end
    T.expect("TWI_RandomArmor", armors_now >= 1, "armor stacks: " .. armors_now)

    local function talents()
        local t = {}
        for _, n in ipairs { "Acrobat", "Pickpocket", "Lockpick", "Sneak", "Mining", "Smith", "Alchemy", "Trophy", "Scribe" } do
            t[n] = (risen.npc.skill_raw(p, risen.item.skill_id(risen.balance.skill_enum(n))))
        end
        return t
    end
    local t0 = talents()
    local changed = false
    for _ = 1, 6 do
        run_and_wait("CHAT bob TWI_RandomTalent")
        local t1 = talents()
        for k, v in pairs(t1) do if v ~= t0[k] then changed = true end end
        if changed then break end
    end
    T.expect("TWI_RandomTalent", changed)
    run_and_wait("CHAT bob TWI_RandomTalents")
    T.expect("TWI_RandomTalents", status().deferred == 0)

    local str0 = risen.npc.skill_raw(p, risen.item.skill_id(risen.balance.skill_enum("Strength")))
    run_and_wait("CHAT bob TWI_RandomStatBonus STR 1 250 5 5")
    local str1 = risen.npc.skill_raw(p, risen.item.skill_id(risen.balance.skill_enum("Strength")))
    T.expect("TWI_RandomStatBonus STR", str1 == str0 + 5, ("%s -> %s"):format(str0, str1))

    -- the gate: while the session is torn down nothing runs
    risen.emit("twitch.gate", false)
    inject("CHAT bob TWI_Money 1000")
    T.sleep(180)
    T.expect("gate closes with the session", status().in_world == false and status().inbox >= 1 and risen.item.money(p) < g + 500)
    T.finish("twitch done")
end, "twitch")
