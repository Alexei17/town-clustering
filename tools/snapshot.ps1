<#
.SYNOPSIS
Recovers a map snapshot from the game log, so a seed can be previewed offline.

.DESCRIPTION
The workflow, once per seed:

  1. Enable Town Clustering and set "Debug: Map Snapshot" to "Snapshot Only".
  2. Start a new game on the seed you want. The mod records the map and leaves
     the towns alone, so nothing is rearranged.
  3. Wait for "snapshot complete" in the log, then quit. The terrain goes out a
     dozen rows per tick, so a large map takes a hundred-odd ticks - a tall map
     measured 1297 rows. Reading the log before that reports how far it got.
  4. Run this script. It reads the log and writes snapshots\<name>.lua.

After that, every setting can be tried against that map in about a second:

  .\tools\studio.ps1 -Snapshot snapshots\<name>.lua -Open

Generation is paid for once per seed instead of once per experiment, and the
minutes of ticks the rebuild normally needs leave the loop entirely.

Set "Debug: Map Snapshot" back to Off for normal play.

.PARAMETER Name
Name for the snapshot, used as the filename. Defaults to a timestamp.

.PARAMETER Log
Path to stdout.txt. Found automatically if not given.

.PARAMETER Preview
Build the studio page as soon as the snapshot is recovered.

.EXAMPLE
.\tools\snapshot.ps1 -Name alpine -Preview

.EXAMPLE
.\tools\snapshot.ps1 -Log "C:\path\to\stdout.txt" -Name seed12345
#>
[CmdletBinding()]
param(
	[string]$Name,
	[string]$Log,
	[switch]$Preview
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot

$Lua = (Get-Command lua -ErrorAction SilentlyContinue).Source
if (-not $Lua) {
	$Candidates = @(
		"$env:LOCALAPPDATA\Programs\Lua\bin\lua.exe",
		"$env:ProgramFiles\Lua\bin\lua.exe",
		"${env:ProgramFiles(x86)}\Lua\bin\lua.exe"
	)
	$Lua = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Lua) {
	throw "Lua not found. Install it with: winget install DEVCOM.Lua"
}

if (-not $Log) {
	# Same discovery deploy.ps1 uses: the per-account userdata folder for appid
	# 3493540.
	$Local = Get-ChildItem "C:\Program Files (x86)\Steam\userdata\*\3493540\local" -Directory -ErrorAction SilentlyContinue |
		Select-Object -First 1
	if (-not $Local) {
		throw "Could not find the TF3 userdata folder. Pass -Log with the path to stdout.txt."
	}
	$Log = Join-Path $Local.FullName "crash_dump\stdout.txt"
}

if (-not (Test-Path $Log)) {
	throw "Log not found: $Log"
}

if (-not $Name) { $Name = "snapshot-" + (Get-Date -Format "yyyyMMdd-HHmmss") }
if ($Name -notlike "*.lua") { $Name = "$Name.lua" }

$OutDir = Join-Path $Root "snapshots"
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
$Out = Join-Path $OutDir $Name

Write-Host "Reading $Log"
& $Lua (Join-Path $PSScriptRoot "preview\from_log.lua") $Log $Out
if ($LASTEXITCODE -ne 0) {
	throw "Could not recover a snapshot. Is Debug: Map Snapshot set to Snapshot Only, and did you start a new game with it on?"
}

Write-Host ""
Write-Host "Preview it with:"
Write-Host "  .\tools\studio.ps1 -Snapshot `"snapshots\$Name`" -Open"

if ($Preview) {
	& (Join-Path $PSScriptRoot "studio.ps1") -Snapshot $Out -Open
}
