# Hebnix portal listing: Lobby Ranks

Paste these into the upload form. Upload files:
- banner: `listing/banner.png` (1600×900)
- plugin: `dist/lobby_ranks-<version>.zip` (build it with `pwsh ./package.ps1`)

## Name

Lobby Ranks

## Category

Utility

## Version

1.0.0

## Short description

See every player's rank, MMR and games played across the playlists you choose, in a table over your scoreboard. A port of the classic BakkesMod plugin.

## Long description

Lobby Ranks shows a table of everyone in your match with their rank, MMR and games played in each playlist you pick. It's a Hebnix port of GrantJL's classic BakkesMod plugin, which stopped working online after Easy Anti-Cheat. This version uses the official Stats API, so it works in online matches.

What it does
• Lists every player in the lobby, grouped by team, with your own name highlighted.
• Shows rank (e.g. C2 D3), MMR and games played for each playlist you choose.
• Playlists: 1v1, 2v2, 3v3, 4v4, Tournament, Casual, Hoops, Rumble, Dropshot, Snow Day and Heatseeker.
• Appears while you hold your scoreboard button, or on a key or controller button you set yourself.

Settings
• Choose which playlists and columns to show (MMR, games played, division, platform).
• Position the table anywhere on screen with anchors and sliders. It scales with your resolution.
• Change the colours for the table, both teams, yourself, every rank tier and every platform.
• Preview mode draws example players, so you can set it up from the main menu.

Notes
• Ranks come from player profile lookups, so a new player shows "..." for a moment while their profile loads. "?" means the lookup failed.
• The Rocket League Stats API must be enabled. Hebnix can do this for you.

Credits
Original BakkesMod plugin by GrantJL (Jayden Grant): github.com/GrantJL/rl-lobby-ranks. This is an independent Lua rewrite for Hebnix. The original author has been contacted about the port. If they object, it will be taken down.
