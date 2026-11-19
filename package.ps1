# Builds the zip to upload to the Hebnix plugin portal, e.g. dist\lobby_ranks-2.0.0.zip
# Hebnix extracts catalog zips straight into its plugins folder, so the zip
# must contain one top-level plugin folder: lobby_ranks/plugin.toml, lobby_ranks/main.lua
#
#   pwsh ./package.ps1            # build the zip
#   pwsh ./package.ps1 -Install   # also copy the plugin into %APPDATA%\Hebnix\plugins

param([switch]$Install)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$plugin = Join-Path $root 'lobby_ranks'

$manifest = Get-Content (Join-Path $plugin 'plugin.toml') -Raw
if ($manifest -notmatch '(?m)^version\s*=\s*"([^"]+)"') { throw 'plugin.toml has no version' }
$version = $Matches[1]

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "lobby_ranks-$version.zip"
if (Test-Path $zip) { Remove-Item $zip }

# Compress-Archive on a folder path keeps the folder as the archive's top level
Compress-Archive -Path $plugin -DestinationPath $zip
Write-Host "Built $zip"

if ($Install) {
    $target = Join-Path $env:APPDATA 'Hebnix\plugins\lobby_ranks'
    New-Item -ItemType Directory -Force $target | Out-Null
    Copy-Item (Join-Path $plugin '*') $target -Recurse -Force
    Write-Host "Installed to $target (reload the plugin in Hebnix)"
}
