# risen-twitch

Twitch integration for Risen Enhanced on top of [risen-spass](../risen-spass), the Risen counterpart of the Gothic II NINJA mods `TwitchIntegration` and `TWI_Kirides`.

| Mod | Role |
|---|---|
| `mods/twitch_integration` | Base. Client of the named pipe `\\.\pipe\__TwitchIntegration_Kirides_Conn` that the Twitch bridge hosts. Reads `TYPE user command [args]` lines (`REWARD_ADD`, `BITS_USED`, `FOLLOW`, `CHAT`) and **executes them only inside a running game session** (after `world.ready`, player alive; not at the main menu, not while loading). Offers each event to the action mods with `risen.emit("twitch.command", ctx)`; a command nobody handles may run as a console command (`console_allow`, default `weather,timescale`). |
| `mods/twi_kirides` | The `TWI_*` actions: `TWI_SpawnEnemy/Npc/NpcImmortal/NpcNamed/NpcOneOf/EnemyOneOf`, `TWI_SpawnRandomMonster[NoLimit]`, `TWI_Raid_Beasts/Lizards`, `TWI_Money`, `TWI_SpawnItemRandom`, `TWI_FullHeal`, `TWI_SetHP[_Timed]`, `TWI_SetMana[_Timed]`, `TWI_RandomHP_Pct`, `TWI_RandomStatBonus`, `TWI_Time`, `TWI_Weather`, `TWI_Southpark`, `TWI_Slowdown`. |
| `mods/twitch_test` | Live scenario `twitch`. |

Not ported (no Risen equivalent yet): `TWI_RandomWaypoint`, `TWI_InvertKeyControls`, `TWI_VoicePitch`, `TWI_Weakest_Weapon`, the random talents / armor, bandit and orc raids (replaced by `TWI_Raid_Beasts` and `TWI_Raid_Lizards`).

## Writing an action mod

```lua
risen.on("twitch.command", function(ctx)      -- ctx: type, user, command, args, argv
    if ctx.command:lower() ~= "my_action" then return end
    if not can_do_it_now() then ctx.defer = true return end   -- offered again later (defer_s)
    do_it(risen.entity.player(), ctx.argv)
    ctx.handled = true
    ctx.message = ctx.user .. " did it"          -- optional HUD text
end)
```

## Test

```powershell
# terminal 1: a stand-in for the bridge (sends one line the moment the game connects, normally at the main menu)
python tools\fake_bridge.py "REWARD_ADD early TWI_Money 123"
# terminal 2, in the risen-spass repository
.\scripts\test-run.ps1 -ModPath ..\risen-twitch\mods -Mods twitch_integration,twi_kirides,twitch_test -WaitForResult -Seconds 300 -Scenario twitch
```

Config of the base mod: `mods/twitch_integration/config.toml` (`risen.config`: `retry_s`, `interval_s`, `max_age_s`, `defer_s`, `print_redemptions`, `console_allow`, `ack`).
