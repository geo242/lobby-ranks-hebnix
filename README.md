# Lobby Ranks for Hebnix

A Hebnix Lua port of [GrantJL's BakkesMod Lobby Ranks](https://github.com/GrantJL/rl-lobby-ranks).
It shows a table of every player in your match, with their rank, MMR and games played across the playlists you pick.
It works in online matches with Easy Anti-Cheat because it only uses the Stats API, tracker profiles and an overlay.

## Install

Copy the `lobby_ranks` folder into `%APPDATA%\Hebnix\plugins\`, then enable **Lobby Ranks** in Hebnix.
The Rocket League Stats API must be enabled. Hebnix can do this for you.

## Usage

- **Hold scoreboard:** the table shows while your scoreboard bind is held. You can turn this off in settings.
- **Toggle key:** in settings, click **Set** next to "Toggle key" and press a key or controller button. This replaces `jlg_lobby_rank_toggle`.
- **Preview:** "Show preview table" draws example players so you can position and colour the table outside a match.

## Mapping from the BakkesMod version

| BakkesMod | Hebnix |
|---|---|
| `server.GetPRIs()` | `UpdateState` event: `Players[]` |
| `MMRWrapper` rank/MMR/games | `fetch_profile_async` → `stats_result().ranks[playlist]` |
| `OnOpenScoreboard` hook | `hebnix.is_action_pressed("scoreboard")` |
| Canvas `FillBox` / `DrawString` | `draw.rect` / `draw.text` / `draw.line` in `on_overlay` |
| ImGui settings + `config.json` | `on_settings(ui)` controls (saved automatically) |

## Credits

The original BakkesMod Lobby Ranks is by [GrantJL (Jayden Grant)](https://github.com/GrantJL/rl-lobby-ranks). This is an independent Lua rewrite for Hebnix that follows the original's design. GrantJL has been contacted about the port through a GitHub issue on the original repo. If they object, it will be taken down.

## Development

- **Run the tests:**
  - `python -m pip install lupa`
  - `python tests/run_tests.py`

  The tests run the plugin against a mocked Hebnix host in Lua 5.4, the same Lua version Hebnix embeds.
- **Build the upload zip:** `pwsh ./package.ps1`. This writes `dist/lobby_ranks-<version>.zip`. Add `-Install` to also copy the plugin into your Hebnix plugins folder.
- **Regenerate the portal banner:**
  - `python -m pip install pillow`
  - `python tools/make_banner.py`

  This writes `listing/banner.png`. The portal listing text is in `listing/listing.md`.
- **Release a new version:** bump `version` in `plugin.toml` for each upload. After the first upload, add the `plugin_id` the Hebnix portal assigns to `plugin.toml`. Hebnix uses that ID to match updates.

Differences from the original:
- Ranks come from tracker profiles rather than the game's memory, so new players show `...` for a moment while their profiles load.
- `?` means the lookup failed.
- Playlists are shown in a fixed order. The original let you reorder them.
