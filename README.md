# risen-twitch

Twitch integration for Risen Enhanced on top of [risen-spass](../risen-spass), the Risen counterpart of the Gothic II NINJA mods `TwitchIntegration` and `TWI_Kirides`.

| Mod | Role |
|---|---|
| `mods/twitch_integration` | Base. Client (read-only) of the named pipe `\\.\pipe\__TwitchIntegration_Kirides_Conn` that `twitch-integration-connector.exe` hosts. Reads its JSON messages (`redemption`, `streamelements-perk`, `bits`, `chat`, `ping`; 2-byte little-endian length in front of each), maps them with **`custom.lua`** (rewards, perks, bits, chat texts -> action lists; replaces the Gothic II `twitch-integration.json`) and **executes the actions only inside a running game session** (after `world.ready`, player alive; not at the main menu, not while loading). Offers each event to the action mods with `risen.emit("twitch.command", ctx)`; a command nobody handles may run as a console command (`console_allow`, default `weather,timescale`). |
| `mods/twi_kirides` | The `TWI_*` actions: `TWI_SpawnEnemy/Npc/NpcImmortal/NpcNamed/NpcOneOf/EnemyOneOf`, `TWI_SpawnRandomMonster[NoLimit]`, `TWI_Raid_Beasts/Lizards`, `TWI_Money`, `TWI_SpawnItemRandom`, `TWI_FullHeal`, `TWI_SetHP[_Timed]`, `TWI_SetMana[_Timed]`, `TWI_RandomHP_Pct`, `TWI_RandomStatBonus`, `TWI_RandomWaypoint`, `TWI_Weakest_Weapon`, `TWI_RandomArmor`, `TWI_RandomTalent[s]`, `TWI_Time`, `TWI_Weather`, `TWI_Southpark`, `TWI_Slowdown`. |
| `mods/twitch_test` | Live scenario `twitch`. |

Not ported yet: `TWI_InvertKeyControls` (probably possible with `risen.input`), `TWI_VoicePitch` (no API found), bandit and orc raids (replaced by `TWI_Raid_Beasts` and `TWI_Raid_Lizards`).

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
# terminal 1: a stand-in for the connector (a message pipe like the real one; sends the messages of the file the moment the game connects,
# normally at the main menu). The real connector must NOT run at the same time: both host the same pipe name.
python tools\fake_bridge.py --file early.jsonl      # early.jsonl: {"type":"streamelements-perk","data":{"title":"Gold","redeemer":"early"}}
# terminal 2, in the risen-spass repository
.\scripts\test-run.ps1 -ModPath ..\risen-twitch\mods -Mods twitch_integration,twi_kirides,twitch_test -WaitForResult -Seconds 300 -Scenario twitch
```

Config of the base mod: `mods/twitch_integration/config.toml` (`risen.config`: `retry_s`, `interval_s`, `max_age_s`, `defer_s`, `print_redemptions`, `console_allow`). What Twitch events do: `mods/twitch_integration/custom.lua` (`rewards`, `perks`, `bits`, `chat`; an entry is a list of actions like `"TWI_Money 100"`, or `{ actions = {...}, cooldown_s = 120 }`). The connector's `cooldown_sec` and `message` of the old json were never used by the Gothic DLL; the cooldown works here.
