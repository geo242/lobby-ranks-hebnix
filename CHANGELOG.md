# Changelog

All notable changes to Lobby Ranks. Versions match the Hebnix plugin portal.

## 1.0.4 (2026-11-19)

- When a rank lookup fails (a slow or busy profile service, for example), it's now tried again after 20, 40 and 60 seconds instead of showing "?" for the rest of the match. A player who isn't found isn't retried.
- The reason for each failed lookup is written to the Hebnix console.
- Console lines no longer repeat the plugin name ("[Lobby Ranks] [Lobby Ranks] ...").

## 1.0.3 (2026-11-18)

- Outside a match (with the preview off), the plugin does nothing every frame and doesn't keep the game overlay active, so it no longer costs anything in menus.

## 1.0.2 (2026-11-18)

- Uses much less CPU in matches: player profiles are read once when they load, the lobby is checked a few times a second instead of every frame, and the table is only rebuilt when something in it changes.

## 1.0.1 (2026-11-17)

- Settings: the color sections are now spelled "Table & team colors", "Rank colors" and "Platform colors". Saved colors are unchanged.
- Credits: GrantJL, the original plugin's author, has given permission for this port.

## 1.0.0 (2026-11-17)

- First release: a Hebnix port of GrantJL's BakkesMod plugin, using the official Stats API. Shows rank, MMR and games played for every player in the lobby across the playlists you choose.
