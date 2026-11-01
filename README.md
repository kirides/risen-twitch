# risen-twitch

Lets Twitch viewers act on your **Risen Enhanced** game: channel-point rewards, StreamElements perks, bits and chat commands spawn monsters, change gold, health, time, weather and more, as if the cheat console had been used.

It is the Risen counterpart of the Gothic II mods `TwitchIntegration` and `TWI_Kirides`, and it uses the **connector** of the original project, [kirides/twitch-integration](https://github.com/kirides/twitch-integration), to talk to Twitch and StreamElements:

```
Twitch / StreamElements  <-->  twitch-integration-connector.exe  --named pipe-->  Risen (risen-spass layer)
                               (original repo, runs next to the game)               twitch_integration  +  twi_kirides
```

The connector holds your Twitch login and hosts the named pipe `\\.\pipe\__TwitchIntegration_Kirides_Conn`. The game only connects to it (read-only, no network socket in the game). In the original project, the Gothic II DLL did the mapping from rewards to actions with `twitch-integration.json`. Here the mod `twitch_integration` does it, and you write the mapping in **`custom.lua`**.

| Mod | Role |
|---|---|
| `mods/twitch_integration` | Base mod. Reads the connector's messages, maps them with `custom.lua` and runs the actions **only inside a running game session**. |
| `mods/twi_kirides` | The `TWI_*` actions (spawn, gold, health, time, ...). |
| `mods/twitch_test` | Test scenario `twitch` (not for players). |

## Setup

You need: Risen Enhanced (64-bit), the **risen-spass** modding layer, and the connector from the original repository.

1. **Install risen-spass** into your Risen folder (it replaces `sentry.dll` with a proxy and creates `bin\spass\mods`):
   ```powershell
   .\install.ps1 -GameDir 'C:\...\Risen'      # from the risen-spass release zip
   ```
   Details: the install section of risen-spass `docs/MODDING_GUIDE.md`. Try a copy of the game first if you are unsure.
2. **Copy the mods** `mods\twitch_integration` and `mods\twi_kirides` of this repository into `<Risen>\bin\spass\mods\`. Do not copy `twitch_test`.
3. **Get the connector.** Download `twitch-integration-connector.exe` from the [original repository](https://github.com/kirides/twitch-integration) (its releases, or build it as described there). Put it in its own folder and start it once: it writes `twitch-integration-connector.json` next to itself and then needs your credentials.
4. **Fill in `twitch-integration-connector.json`** (the details are in the original README):
   ```json
   {
     "twitch": {
       "channel": "your_channel_name",
       "oauth_token": "<token with chat:read, bits:read, channel:read:redemptions, channel:read:subscriptions>",
       "channel_points": true,
       "bits": true,
       "chat": true,
       "command_prefix": "#"
     },
     "streamElements": { "enabled": false, "token": "<JWT from streamelements.com/dashboard/account/channels>", "channel": "your_channel_name" }
   }
   ```
   The default file contains the link to create the OAuth token. Leave `streamElements.enabled` off if you do not use StreamElements.
5. **Edit `custom.lua`** in `<Risen>\bin\spass\mods\twitch_integration\` so that your rewards, perks, bits and chat commands do something (see below). The shipped file is an example.
6. **Run** `twitch-integration-connector.exe` and start Risen. Order does not matter: the game tries to connect every 5 seconds until the connector is there.

Check `<Risen>\bin\spass\spass.log` for lines starting with `pipe:` and `twitch:`. In the game, an executed action prints a line in the HUD's game log.

## `custom.lua`: what Twitch events do

```lua
return {
    -- channel-point reward title -> actions (upper/lower case does not matter)
    rewards = {
        ["Beast Raid"]  = { "TWI_Raid_Beasts 3" },
        ["Stat Roulette"] = { "TWI_RandomStatBonus STR 10 250 -10 10", "TWI_RandomStatBonus HP 20 600 -10 10" },
    },
    -- StreamElements perk name -> actions
    perks = { ["Gold"] = { "TWI_Money 150" } },
    -- exact number of bits -> actions
    bits  = { [100] = { "TWI_SpawnRandomMonster 2", "TWI_Money 100" } },
    -- exact chat text -> actions (the connector only forwards texts that start with its command_prefix)
    chat  = { ["#weak"] = { actions = { "TWI_Weakest_Weapon" }, cooldown_s = 120 } },
}
```

* An entry is a list of actions, run one after the other, each `"COMMAND arguments"`. Instead of the list it may be `{ actions = {...}, cooldown_s = 120 }`; the cooldown (seconds) is kept per chat text. The `cooldown_sec` of the old json was read but never applied by the Gothic II DLL; here it works. The old `message` field (a chat reply) is not supported.
* Reload after editing: restart the game, or reload the mod (risen-spass mod manager in the ESC menu, or `risen.mods.reload`).
* The user name that the connector sends (spaces removed) is shown on every NPC or monster an action spawns: when you look at it, its label is `<user>'s <Template>`. The label is lost when a savegame is loaded.

## When actions run

Actions run **only inside a running game session**: after the world is ready and while the player is alive. Not at the main menu, not while a savegame loads, not while a menu pauses the world, not while the player is dead. Events that arrive earlier wait in a queue and run when the game is ready, but events older than `max_age_s` (default 5 minutes) are dropped, so a long pause does not unleash a backlog. At most one event runs every `interval_s` (0.5 s). An action that cannot run right now (for example nothing could be spawned) is retried for `defer_s` (2 minutes).

Settings of the base mod are in `<Risen>\bin\spass\mods\twitch_integration\config.toml` (create it if you want to change a value; unknown keys are ignored):

| Key | Default | Meaning |
|---|---|---|
| `retry_s` | 5 | seconds between connection attempts while the connector is not running |
| `interval_s` | 0.5 | at most one event per this many seconds |
| `max_age_s` | 300 | drop events that waited longer outside a session (0 = never) |
| `defer_s` | 120 | how long a "not now" event is retried |
| `max_deferred` | 40 | size of that retry queue |
| `print_redemptions` | true | HUD game-log line for every executed action |
| `console_allow` | `"weather,timescale"` | game console commands a mapped action may run directly (comma separated, `""` = none) |

## Actions

Command names are not case sensitive. `[x]` is optional.

| Action | What it does |
|---|---|
| `TWI_SpawnEnemy <template> [n]` | spawns `n` (1..10) hostile creatures 5 to 9 m from the player |
| `TWI_SpawnNpc <template> [n]` / `TWI_SpawnNpcImmortal <template> [n]` | peaceful NPCs (the second with 100000 hit points) |
| `TWI_SpawnNpcNamed <name> <template> [n]` | peaceful NPCs labelled with `<name>` |
| `TWI_SpawnNpcOneOf <template...>` / `TWI_SpawnEnemyOneOf <template...>` | one random template of the list |
| `TWI_SpawnRandomMonster [n]` | random monsters of the current chapter |
| `TWI_SpawnRandomMonsterNoLimit [n]` | random monsters of any chapter (Titan, Inferno, ...) |
| `TWI_Raid_Beasts [n]` / `TWI_Raid_Lizards [n]` | a group (random size 1..3, up to 12) of chapter-fitting beasts or lizard folk |
| `TWI_Money <amount>` | gives gold; a negative amount takes gold (never more than the player has) |
| `TWI_SpawnItemRandom` | gives a random potion, food, plant, scroll, weapon, valuable, ring or amulet |
| `TWI_FullHeal` | restores hit points and mana |
| `TWI_SetHP <n>` / `TWI_SetMana <n>` | sets hit points / mana (hit points at least 1) |
| `TWI_SetHP_Timed <n> <seconds>` / `TWI_SetMana_Timed <n> <seconds>` | holds hit points / mana at no more than `n` for that long |
| `TWI_RandomHP_Pct <min> <max>` | hit points to a random percentage of the maximum |
| `TWI_RandomStatBonus <STR\|DEX\|INT\|HP\|MANA> <min> <max> <low> <high>` | changes the attribute by a random value in `low..high`, the result stays within `min..max` |
| `TWI_RandomTalent` / `TWI_RandomTalents` | sets one / all of Acrobat, Pickpocket, Lockpick, Sneak, Mining, Smith, Alchemy, Trophy, Scribe to a random value |
| `TWI_RandomArmor` | gives and equips a random body armor (one the player can wear, if there is one) |
| `TWI_Weakest_Weapon` | equips the carried weapon with the lowest damage |
| `TWI_RandomWaypoint` | teleports the player to a random freepoint of the world |
| `TWI_Time <0..23>` | sets the hour |
| `TWI_Weather <state>` | forces a weather state (for example `Foggy_Rain`) |
| `TWI_Southpark <seconds>` / `TWI_Slowdown <seconds>` | game speed 2x / 0.4x for that long (1 to 300 s) |

Template names are listed in risen-spass `docs/TEMPLATES.md` (`Monster/Kapitel 1..4`, `Items/...`). A bad argument is logged as a warning and the event is dropped. An unknown command is logged (`twitch: nobody handles '...'`) and dropped.

**Not ported from the Gothic II version:** `TWI_InvertKeyControls`, `TWI_VoicePitch`, and the bandit and orc raids (Risen has no orcs; `TWI_Raid_Beasts` and `TWI_Raid_Lizards` take their place).

## Writing your own action

Another mod (or a new file in `twi_kirides`) answers the event `twitch.command`:

```lua
risen.on("twitch.command", function(ctx)      -- ctx: type, user, command, args (string), argv (list)
    if ctx.command:lower() ~= "twi_my_action" then return end
    if not can_do_it_now() then ctx.defer = true return end   -- offered again later (defer_s)
    do_it(risen.entity.player(), ctx.argv)
    ctx.handled = true
    ctx.message = ctx.user .. " did it"          -- optional HUD text
end)
```

An action that nobody handles may still be a game console command listed in `console_allow`. Put the new command into `custom.lua` and it is used.

## Troubleshooting

* **Nothing happens, log says `pipe: ... connecting`:** the connector is not running, or another program (a second connector, a test bridge) already hosts the pipe. Only one program can host `__TwitchIntegration_Kirides_Conn` at a time.
* **`twitch: nobody handles '...'`:** the command in `custom.lua` has no action. Check the spelling against the table above.
* **`twitch: custom.lua could not be loaded`:** a Lua syntax error in `custom.lua`; the message names the line.
* **Events come late:** they wait for a running session (see above), and one event runs every half second.

## Tests

The scenario `twitch` (30 checks) runs the whole chain in the real game with a stand-in connector: a pipe that behaves like the real one (message pipe, length-prefixed JSON, ping every 5 s). It has not been run against Twitch itself. **Close the real connector first** (same pipe name).

```powershell
# terminal 1: sends the messages of the file the moment the game connects (normally at the main menu)
python tools\fake_bridge.py --file early.jsonl      # early.jsonl: {"type":"streamelements-perk","data":{"title":"Gold","redeemer":"early"}}
# terminal 2, in the risen-spass repository
.\scripts\test-run.ps1 -ModPath ..\risen-twitch\mods -Mods twitch_integration,twi_kirides,twitch_test -WaitForResult -Seconds 300 -Scenario twitch
```

## Credits

The connector, the pipe protocol and the idea come from [kirides/twitch-integration](https://github.com/kirides/twitch-integration). The game-side layer is risen-spass.
