<#
.SYNOPSIS
  One-command setup for quotabot from source on Windows.

.DESCRIPTION
  Builds and installs the quotabot CLI, and (by default) the desktop app with a
  Start-menu/Desktop shortcut, then runs `quotabot doctor`. Idempotent: safe to
  re-run after a `git pull`. Everything stays local; no telemetry, no account.

  An AI agent can run this unattended:  pwsh tools/setup.ps1 -Yes

.PARAMETER CliOnly
  Build and install only the CLI (skip the desktop app and shortcut).

.PARAMETER NoApp
  Build and install the CLI; skip building the desktop app, but nothing else.

.PARAMETER Yes
  Non-interactive: assume yes to prompts (for agents and CI).

.EXAMPLE
  pwsh tools/setup.ps1
  pwsh tools/setup.ps1 -CliOnly
#>
[CmdletBinding()]
param(
  [switch]$CliOnly,
  [switch]$NoApp,
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$collector = Join-Path $root 'collector'
$app = Join-Path $root 'app'
$installDir = Join-Path $env:LOCALAPPDATA 'quotabot\bin'

# Resolve the Flutter/Dart bin directory from PATH, falling back to common
# install locations, so this works on any machine.
function Resolve-DartBin {
  foreach ($name in @('dart', 'flutter')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return Split-Path -Parent $cmd.Source }
  }
  foreach ($c in @(
      "$env:LOCALAPPDATA\flutter\bin", 'C:\flutter\bin', 'C:\src\flutter\bin',
      "$env:USERPROFILE\flutter\bin")) {
    if (Test-Path (Join-Path $c 'dart.bat')) { return $c }
  }
  throw "Dart/Flutter not found. Install Flutter (https://docs.flutter.dev/get-started/install) and re-run."
}

Write-Step 'Locating the Dart toolchain'
$dartBin = Resolve-DartBin
$env:Path = "$dartBin;$dartBin\cache\dart-sdk\bin;$env:Path"
$dartVer = (& dart --version 2>&1 | Select-Object -First 1)
Write-Ok $dartVer

Write-Step 'Building the quotabot CLI'
Push-Location $collector
try {
  & dart pub get | Out-Null
  & (Join-Path $scriptDir 'package-cli.ps1')
} finally { Pop-Location }

$asset = Join-Path $root 'release\quotabot-windows-x64.exe'
if (-not (Test-Path $asset)) { throw "CLI build did not produce $asset" }

Write-Step "Installing the CLI to $installDir"
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$exe = Join-Path $installDir 'quotabot.exe'
Copy-Item $asset $exe -Force
Write-Ok "Installed quotabot.exe"

# Add the install dir to the user PATH if it is not already there.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$installDir*") {
  [Environment]::SetEnvironmentVariable('Path', "$installDir;$userPath", 'User')
  Write-Ok "Added $installDir to your PATH (restart the terminal to pick it up)"
} else {
  Write-Ok 'Install dir already on PATH'
}

if (-not $CliOnly -and -not $NoApp) {
  Write-Step 'Building the desktop app (this takes a few minutes)'
  Push-Location $app
  try {
    & flutter build windows --release
  } finally { Pop-Location }

  Write-Step 'Creating the Desktop shortcut'
  & (Join-Path $scriptDir 'create-shortcut.ps1')
}

Write-Step 'Verifying with quotabot doctor'
try {
  & $exe doctor
} catch {
  Write-Warn2 "doctor reported an issue (this is expected if no provider tools have run yet): $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'quotabot is set up.' -ForegroundColor Green
Write-Host '  CLI:   quotabot --help        (new terminal, or run from ' -NoNewline; Write-Host $exe -NoNewline; Write-Host ')'
if (-not $CliOnly -and -not $NoApp) {
  Write-Host '  App:   launch from the Desktop shortcut, or it lives in your system tray'
}
Write-Host '  Route: quotabot suggest        (which subscription to use next)'
