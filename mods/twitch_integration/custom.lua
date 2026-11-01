-- What Twitch events do in the game. This file replaces the twitch-integration.json of the Gothic II version; edit it and reload the mod
-- (risen.mods.reload / the editor's Play button / restart the game).
--
-- Every entry is a list of actions, "command arguments", run one after the other (each action is one event for the action mods, see
-- twi_kirides). Instead of the list an entry may be { actions = { ... }, cooldown_s = 120 } (chat only: the same chat text is ignored for that long).
--
--   rewards   channel-point reward title  -> actions      (the title is compared without regard to upper/lower case)
--   perks     StreamElements perk name    -> actions      (same)
--   bits      exact number of bits        -> actions
--   chat      exact chat text             -> actions      (the connector only forwards texts that start with its command_prefix, "#")

return {
    rewards = {
        ["Spawn Monster"]   = { "TWI_SpawnRandomMonster 1" },
        ["Beast Raid"]      = { "TWI_Raid_Beasts 3" },
        ["Lizard Raid"]     = { "TWI_Raid_Lizards 3" },
        ["Random Armor"]    = { "TWI_RandomArmor" },
        ["Random Talents"]  = { "TWI_RandomTalents" },
        ["Teleport"]        = { "TWI_RandomWaypoint" },
        ["Gift: Random Item"] = { "TWI_SpawnItemRandom" },
        ["Stat Roulette"]   = {
            "TWI_RandomStatBonus STR 10 250 -10 10",
            "TWI_RandomStatBonus DEX 10 250 -10 10",
            "TWI_RandomStatBonus HP 20 600 -10 10",
            "TWI_RandomStatBonus MANA 5 300 -10 10",
        },
    },

    perks = {
        ["Gold"]            = { "TWI_Money 150" },
        ["Tax"]             = { "TWI_Money -150" },
    },

    bits = {
        [50]  = { "TWI_SpawnRandomMonster 1" },
        [100] = { "TWI_SpawnRandomMonster 2", "TWI_Money 100" },
    },

    chat = {
        ["#weak"]        = { actions = { "TWI_Weakest_Weapon" }, cooldown_s = 120 },
        ["#hp_1"]        = { actions = { "TWI_SetHP 1" }, cooldown_s = 120 },
        ["#hp_1_5s"]     = { actions = { "TWI_SetHP_Timed 1 5" }, cooldown_s = 120 },
        ["#mana_0"]      = { actions = { "TWI_SetMana 0" }, cooldown_s = 120 },
        ["#mana_0_5s"]   = { actions = { "TWI_SetMana_Timed 0 5" }, cooldown_s = 120 },
        ["#raid_beasts"] = { actions = { "TWI_Raid_Beasts" }, cooldown_s = 120 },
        ["#raid_lizards"] = { actions = { "TWI_Raid_Lizards" }, cooldown_s = 120 },
        ["#donate_50"]   = { actions = { "TWI_Money -50" }, cooldown_s = 600 },
        ["#donate_100"]  = { actions = { "TWI_Money -100" }, cooldown_s = 600 },
        ["#speed_10"]    = { actions = { "TWI_Southpark 10" }, cooldown_s = 20 },
        ["#speed_30"]    = { actions = { "TWI_Southpark 30" }, cooldown_s = 40 },
        ["#time_day"]    = { actions = { "TWI_Time 8" }, cooldown_s = 120 },
        ["#time_night"]  = { actions = { "TWI_Time 21" }, cooldown_s = 120 },
        ["#teleport"]    = { actions = { "TWI_RandomWaypoint" }, cooldown_s = 300 },
    },
}
