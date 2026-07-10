<#
.SYNOPSIS
  One-command setup for quotabot from source on Windows.

.DESCRIPTION
  Builds and installs the quotabot CLI, and (by default) the desktop app with a
  Desktop shortcut, then runs `quotabot doctor`. Idempotent: safe to
  re-run after a `git pull`. No quotabot account or telemetry is used.
  `doctor` reads quota metadata only: no prompts, code, inference requests, or
  usage-token-spending calls.

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
$installRoot = Join-Path $env:LOCALAPPDATA 'quotabot'
$installDir = Join-Path $installRoot 'bin'
. (Join-Path $scriptDir 'windows-build-prereqs.ps1')
. (Join-Path $scriptDir 'windows-architecture.ps1')
$windowsArch = Get-QuotabotWindowsArchitecture

# Resolve the Flutter/Dart bin directory from PATH, falling back to common
# user-owned install locations. The fallbacks are deliberately limited to
# per-user directories: C:\ is world-creatable by default, so trusting
# C:\flutter\bin\dart.bat would let any local user plant a binary that this
# script then runs. If Flutter lives elsewhere, add it to PATH and it is found
# by the Get-Command check above.
function Resolve-DartBin {
  foreach ($name in @('dart', 'flutter')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return Split-Path -Parent $cmd.Source }
  }
  foreach ($c in @(
      "$env:LOCALAPPDATA\flutter\bin", "$env:USERPROFILE\flutter\bin")) {
    if (Test-Path (Join-Path $c 'dart.bat')) { return $c }
  }
  throw "Dart/Flutter not found on PATH. Install Flutter (https://docs.flutter.dev/get-started/install), or add its bin directory to PATH, and re-run."
}

function Resolve-BuiltAppExe {
  Get-QuotabotWindowsBuiltAppExecutable -AppRoot $app -Architecture $windowsArch
}

function Get-RunningDesktopApp($exePath) {
  if (-not $exePath) { return @() }
  $resolvedExe = [IO.Path]::GetFullPath($exePath)
  $matches = @()
  foreach ($proc in Get-Process quotabot -ErrorAction SilentlyContinue) {
    try {
      if ($proc.Path -and ([IO.Path]::GetFullPath($proc.Path) -ieq $resolvedExe)) {
        $matches += $proc
      }
    } catch {
      # Some process paths can be inaccessible; ignore them rather than
      # stopping an unrelated quotabot CLI or service.
    }
  }
  return $matches
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

$asset = Get-QuotabotWindowsReleaseArchive -RepositoryRoot $root -Architecture $windowsArch
if (-not (Test-Path -LiteralPath $asset)) {
  throw "CLI build did not produce $(Split-Path -Leaf $asset) in release/"
}

Write-Step "Installing the CLI to $installRoot"
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
$extractPath = Join-Path ([IO.Path]::GetTempPath()) "quotabot-setup-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Force -Path $extractPath
try {
  Expand-Archive -LiteralPath $asset -DestinationPath $extractPath -Force
  $downloadedExe = Join-Path $extractPath 'bin\quotabot.exe'
  $downloadedSqlite = Join-Path $extractPath 'lib\sqlite3.dll'
  if (-not (Test-Path -LiteralPath $downloadedExe)) {
    throw "CLI archive did not contain bin\quotabot.exe"
  }
  if (-not (Test-Path -LiteralPath $downloadedSqlite)) {
    throw "CLI archive did not contain lib\sqlite3.dll"
  }
  # Do not swallow a removal failure: a running quotabot holding the exe open
  # would otherwise leave the old bin/ and nest the new bundle at bin\bin, so
  # PATH would keep the stale binary while setup reports success.
  $binDst = Join-Path $installRoot 'bin'
  $libDst = Join-Path $installRoot 'lib'
  try {
    if (Test-Path -LiteralPath $binDst) { Remove-Item -LiteralPath $binDst -Recurse -Force }
    if (Test-Path -LiteralPath $libDst) { Remove-Item -LiteralPath $libDst -Recurse -Force }
  } catch {
    throw "Could not replace the existing install. Close any running quotabot (for example 'quotabot top' or the MCP server) and re-run. ($($_.Exception.Message))"
  }
  Copy-Item -LiteralPath (Join-Path $extractPath 'bin') -Destination $installRoot -Recurse
  Copy-Item -LiteralPath (Join-Path $extractPath 'lib') -Destination $installRoot -Recurse
} finally {
  Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
}
$exe = Join-Path $installDir 'quotabot.exe'
foreach ($legacy in @('quotabot.ps1', 'quotabot.cmd', 'quotabot.bat')) {
  $legacyPath = Join-Path $installDir $legacy
  if (Test-Path $legacyPath) {
    Remove-Item -LiteralPath $legacyPath -Force
    Write-Ok "Removed legacy shim $legacy"
  }
}
Write-Ok "Installed quotabot.exe"

# Add the install dir to the user PATH if it is not already there. Compare exact
# entries, not a -like substring: a wildcard metacharacter in the path (for
# example a bracket in the username) would make -like miss the existing entry
# and append a duplicate on every run.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$userPaths = @($userPath -split ';' | Where-Object { $_ })
if ($userPaths -notcontains $installDir) {
  [Environment]::SetEnvironmentVariable('Path', "$installDir;$userPath", 'User')
  Write-Ok "Added $installDir to your PATH (restart the terminal to pick it up)"
} else {
  Write-Ok 'Install dir already on PATH'
}

if (-not $CliOnly -and -not $NoApp) {
  $wasRunningApp = $false
  $existingAppExe = Resolve-BuiltAppExe
  $runningApp = Get-RunningDesktopApp $existingAppExe
  if ($runningApp.Count -gt 0) {
    $wasRunningApp = $true
    Write-Step 'Stopping the running desktop app so the rebuilt app is used'
    foreach ($proc in $runningApp) {
      Stop-Process -Id $proc.Id -Force
    }
    foreach ($proc in $runningApp) {
      try { Wait-Process -Id $proc.Id -Timeout 10 } catch {}
    }
  }

  Write-Step 'Building the desktop app (this takes a few minutes)'
  $windowsBuildPrereqs = Assert-WindowsDesktopBuildPrereqs
  if ($windowsBuildPrereqs) {
    Write-Ok "Visual Studio ATL ready: $($windowsBuildPrereqs.VisualStudioPath)"
  }
  Push-Location $app
  try {
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed with exit code $LASTEXITCODE" }
  } finally { Pop-Location }

  $builtAppExe = Resolve-BuiltAppExe
  if (-not $builtAppExe) { throw "Desktop build finished, but quotabot.exe was not found under app\build\windows" }

  Write-Step 'Creating the Desktop shortcut'
  & (Join-Path $scriptDir 'create-shortcut.ps1') -ExePath $builtAppExe

  if ($wasRunningApp) {
    Start-Process -FilePath $builtAppExe -WorkingDirectory (Split-Path -Parent $builtAppExe)
    Write-Ok 'Restarted the desktop app from the rebuilt Release folder'
  }
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
