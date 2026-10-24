<#
.SYNOPSIS
Builds the interactive explorer: all four sliders on one page, live.

.DESCRIPTION
Every combination of the five mod sliders - 6 x 4 x 5 x 4 x 4 = 1920 of them - is
worked out by clustering_core.lua, the file the mod itself runs, and baked into
a single self-contained page. Moving a slider swaps between precomputed results,
so it responds instantly.

There is deliberately no JavaScript implementation of the clustering. All 1920
take a few seconds to compute, so a second implementation would buy nothing and
would drift from the mod exactly when it was being used to tune it.

The page needs no server, no network and no toolchain to open - just a browser.

.PARAMETER Snapshot
A Lua file returning a snapshot table, as written by tools\snapshot.ps1. Defaults
to a synthetic map.

.PARAMETER Out
Where to write the page. Default studio.html in the repository root.

.PARAMETER Open
Open the page when it has been written.

.EXAMPLE
.\tools\studio.ps1 -Open

.EXAMPLE
.\tools\studio.ps1 -Snapshot snapshots\alpine.lua -Open
#>
[CmdletBinding()]
param(
	[string]$Snapshot,
	[string]$Out,
	[switch]$Open
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $Root "studio.html" }

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

$Script = Join-Path $PSScriptRoot "preview\studio.lua"

$Args = @()
if ($Snapshot) { $Args += $Snapshot }
$Args += @("--out", $Out)

Push-Location $Root
try {
	& $Lua $Script @Args
	if ($LASTEXITCODE -ne 0) {
		throw "Studio build failed with exit code $LASTEXITCODE"
	}
}
finally {
	Pop-Location
}

if ($Open) { Invoke-Item $Out }
