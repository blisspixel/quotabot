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

function Install-QuotabotPayload {
  param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$InstallRoot
  )

  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  $transaction = [guid]::NewGuid().ToString('N')
  $binDst = Join-Path $InstallRoot 'bin'
  $libDst = Join-Path $InstallRoot 'lib'
  $stagedBin = Join-Path $InstallRoot ".quotabot-bin-new-$transaction"
  $stagedLib = Join-Path $InstallRoot ".quotabot-lib-new-$transaction"
  $backupBin = Join-Path $InstallRoot ".quotabot-bin-previous-$transaction"
  $backupLib = Join-Path $InstallRoot ".quotabot-lib-previous-$transaction"
  $binBackedUp = $false
  $libBackedUp = $false
  $binInstalled = $false
  $libInstalled = $false
  $lockPath = Join-Path $InstallRoot '.quotabot-install.lock'
  $installLock = $null

  try {
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'bin') -Destination $stagedBin -Recurse
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'lib') -Destination $stagedLib -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $stagedBin 'quotabot.exe') -PathType Leaf)) {
      throw 'Staged payload is missing bin\quotabot.exe'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stagedLib 'sqlite3.dll') -PathType Leaf)) {
      throw 'Staged payload is missing lib\sqlite3.dll'
    }
    try {
      $installLock = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
      )
    } catch {
      throw 'Another quotabot install is already activating a bundle. Re-run after it finishes.'
    }

    if (Test-Path -LiteralPath $binDst) {
      Move-Item -LiteralPath $binDst -Destination $backupBin
      $binBackedUp = $true
    }
    if (Test-Path -LiteralPath $libDst) {
      Move-Item -LiteralPath $libDst -Destination $backupLib
      $libBackedUp = $true
    }
    Move-Item -LiteralPath $stagedBin -Destination $binDst
    $binInstalled = $true
    Move-Item -LiteralPath $stagedLib -Destination $libDst
    $libInstalled = $true
  } catch {
    $installError = $_.Exception.Message
    try {
      if ($binInstalled -and (Test-Path -LiteralPath $binDst)) {
        Remove-Item -LiteralPath $binDst -Recurse -Force
      }
      if ($libInstalled -and (Test-Path -LiteralPath $libDst)) {
        Remove-Item -LiteralPath $libDst -Recurse -Force
      }
      if ($binBackedUp -and (Test-Path -LiteralPath $backupBin)) {
        Move-Item -LiteralPath $backupBin -Destination $binDst
        $binBackedUp = $false
      }
      if ($libBackedUp -and (Test-Path -LiteralPath $backupLib)) {
        Move-Item -LiteralPath $backupLib -Destination $libDst
        $libBackedUp = $false
      }
    } catch {
      throw "Install failed and rollback was incomplete. Recovery payloads remain under $InstallRoot. Original error: $installError. Rollback error: $($_.Exception.Message)"
    } finally {
      Remove-Item -LiteralPath $stagedBin -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $stagedLib -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw "Could not replace the existing install; it was left intact or restored. Close any running quotabot process and re-run. ($installError)"
  } finally {
    if ($installLock) {
      $installLock.Dispose()
    }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }

  foreach ($backup in @($backupBin, $backupLib)) {
    if (Test-Path -LiteralPath $backup) {
      try {
        Remove-Item -LiteralPath $backup -Recurse -Force
      } catch {
        Write-Warning "The new install is active, but the previous payload could not be removed: $backup"
      }
    }
  }
}

function Install-QuotabotDesktopPayload {
  param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$InstallRoot
  )

  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  $transaction = [guid]::NewGuid().ToString('N')
  $desktopDst = Join-Path $InstallRoot 'desktop'
  $stagedDesktop = Join-Path $InstallRoot ".quotabot-desktop-new-$transaction"
  $backupDesktop = Join-Path $InstallRoot ".quotabot-desktop-previous-$transaction"
  $desktopBackedUp = $false
  $desktopInstalled = $false
  $lockPath = Join-Path $InstallRoot '.quotabot-desktop-install.lock'
  $installLock = $null

  try {
    Copy-Item -LiteralPath $SourceRoot -Destination $stagedDesktop -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $stagedDesktop 'quotabot.exe') -PathType Leaf)) {
      throw 'Staged desktop payload is missing quotabot.exe'
    }
    try {
      $installLock = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
      )
    } catch {
      throw 'Another quotabot desktop install is already activating a bundle. Re-run after it finishes.'
    }

    if (Test-Path -LiteralPath $desktopDst) {
      Move-Item -LiteralPath $desktopDst -Destination $backupDesktop
      $desktopBackedUp = $true
    }
    Move-Item -LiteralPath $stagedDesktop -Destination $desktopDst
    $desktopInstalled = $true
  } catch {
    $installError = $_.Exception.Message
    try {
      if ($desktopInstalled -and (Test-Path -LiteralPath $desktopDst)) {
        Remove-Item -LiteralPath $desktopDst -Recurse -Force
      }
      if ($desktopBackedUp -and (Test-Path -LiteralPath $backupDesktop)) {
        Move-Item -LiteralPath $backupDesktop -Destination $desktopDst
        $desktopBackedUp = $false
      }
    } catch {
      throw "Desktop install failed and rollback was incomplete. Recovery payloads remain under $InstallRoot. Original error: $installError. Rollback error: $($_.Exception.Message)"
    } finally {
      Remove-Item -LiteralPath $stagedDesktop -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw "Could not replace the existing desktop install; it was left intact or restored. Close the running quotabot desktop app and re-run. ($installError)"
  } finally {
    if ($installLock) {
      $installLock.Dispose()
    }
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }

  if (Test-Path -LiteralPath $backupDesktop) {
    try {
      Remove-Item -LiteralPath $backupDesktop -Recurse -Force
    } catch {
      Write-Warning "The new desktop install is active, but the previous payload could not be removed: $backupDesktop"
    }
  }
}

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
  Install-QuotabotPayload -SourceRoot $extractPath -InstallRoot $installRoot
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
  $desktopInstallRoot = Join-Path $installRoot 'desktop'
  $installedAppExe = Join-Path $desktopInstallRoot 'quotabot.exe'
  $legacyBuiltAppExe = Resolve-BuiltAppExe
  $runningApp = @(
    @($installedAppExe, $legacyBuiltAppExe) |
      Where-Object { $_ } |
      Sort-Object -Unique |
      ForEach-Object { Get-RunningDesktopApp $_ }
  )
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

  Write-Step "Installing the desktop app to $desktopInstallRoot"
  Install-QuotabotDesktopPayload `
    -SourceRoot (Split-Path -Parent $builtAppExe) `
    -InstallRoot $installRoot
  $installedAppExe = Join-Path $desktopInstallRoot 'quotabot.exe'

  Write-Step 'Creating the Desktop shortcut'
  & (Join-Path $scriptDir 'create-shortcut.ps1') -ExePath $installedAppExe

  if ($wasRunningApp) {
    Start-Process -FilePath $installedAppExe -WorkingDirectory $desktopInstallRoot
    Write-Ok 'Restarted the desktop app from its installed location'
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
