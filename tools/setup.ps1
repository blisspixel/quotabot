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

function Invoke-QuotabotPayloadTransaction {
  param(
    [string]$CliSourceRoot,
    [string]$DesktopSourceRoot,
    [Parameter(Mandatory)][string]$InstallRoot
  )

  if (-not $CliSourceRoot -and -not $DesktopSourceRoot) {
    throw 'At least one quotabot payload source is required.'
  }

  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  $transaction = [guid]::NewGuid().ToString('N')
  $activationSucceeded = $false
  $rollbackComplete = $false
  $locks = @()
  $cli = $null
  $desktop = $null

  if ($CliSourceRoot) {
    $versionsRoot = Join-Path $InstallRoot 'cli-versions'
    $versionRoot = Join-Path $versionsRoot $transaction
    $cli = @{
      SourceRoot = $CliSourceRoot
      BinDst = Join-Path $InstallRoot 'bin'
      LibDst = Join-Path $InstallRoot 'lib'
      VersionsRoot = $versionsRoot
      StagedPayload = Join-Path $InstallRoot ".quotabot-payload-new-$transaction"
      VersionRoot = $versionRoot
      VersionBin = Join-Path $versionRoot 'bin'
      VersionLib = Join-Path $versionRoot 'lib'
      StagedBinLink = Join-Path $InstallRoot ".quotabot-bin-link-new-$transaction"
      StagedLibLink = Join-Path $InstallRoot ".quotabot-lib-link-new-$transaction"
      BackupBin = Join-Path $InstallRoot ".quotabot-bin-previous-$transaction"
      BackupLib = Join-Path $InstallRoot ".quotabot-lib-previous-$transaction"
      BinBackedUp = $false
      LibBackedUp = $false
      BinActivated = $false
      LibActivated = $false
      VersionStaged = $false
    }
  }
  if ($DesktopSourceRoot) {
    $desktop = @{
      SourceRoot = $DesktopSourceRoot
      DesktopDst = Join-Path $InstallRoot 'desktop'
      StagedDesktop = Join-Path $InstallRoot ".quotabot-desktop-new-$transaction"
      BackupDesktop = Join-Path $InstallRoot ".quotabot-desktop-previous-$transaction"
      DesktopBackedUp = $false
      DesktopActivated = $false
    }
  }

  function Remove-TransactionPath {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ($item.LinkType) {
      Remove-Item -LiteralPath $Path -Force
    } else {
      Remove-Item -LiteralPath $Path -Recurse -Force
    }
  }

  function Stage-CliPayload {
    param([Parameter(Mandatory)][hashtable]$State)

    if (Test-Path -LiteralPath $State.VersionsRoot) {
      $versionsItem = Get-Item -LiteralPath $State.VersionsRoot -Force
      if ($versionsItem.LinkType) {
        throw "Refusing to use a link as the CLI generation directory: $($State.VersionsRoot)"
      }
    } else {
      New-Item -ItemType Directory -Path $State.VersionsRoot | Out-Null
    }
    if (Test-Path -LiteralPath $State.VersionRoot) {
      throw "Could not allocate a unique CLI generation: $($State.VersionRoot)"
    }

    New-Item -ItemType Directory -Path $State.StagedPayload | Out-Null
    Copy-Item -LiteralPath (Join-Path $State.SourceRoot 'bin') -Destination $State.StagedPayload -Recurse
    Copy-Item -LiteralPath (Join-Path $State.SourceRoot 'lib') -Destination $State.StagedPayload -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $State.StagedPayload 'bin\quotabot.exe') -PathType Leaf)) {
      throw 'Staged payload is missing bin\quotabot.exe'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $State.StagedPayload 'lib\sqlite3.dll') -PathType Leaf)) {
      throw 'Staged payload is missing lib\sqlite3.dll'
    }
    Move-Item -LiteralPath $State.StagedPayload -Destination $State.VersionRoot
    $State.VersionStaged = $true

    # Dart resolves native assets through the final target of the bin
    # junction. Every invocation sees the executable and sibling lib directory
    # from one complete generation during the compatibility-link switch.
    New-Item -ItemType Junction -Path $State.StagedBinLink -Target $State.VersionBin | Out-Null
    New-Item -ItemType Junction -Path $State.StagedLibLink -Target $State.VersionLib | Out-Null
  }

  function Stage-DesktopPayload {
    param([Parameter(Mandatory)][hashtable]$State)

    Copy-Item -LiteralPath $State.SourceRoot -Destination $State.StagedDesktop -Recurse
    if (-not (Test-Path -LiteralPath (Join-Path $State.StagedDesktop 'quotabot.exe') -PathType Leaf)) {
      throw 'Staged desktop payload is missing quotabot.exe'
    }
  }

  function Activate-DesktopPayload {
    param([Parameter(Mandatory)][hashtable]$State)

    if (Test-Path -LiteralPath $State.DesktopDst) {
      Move-Item -LiteralPath $State.DesktopDst -Destination $State.BackupDesktop
      $State.DesktopBackedUp = $true
    }
    Move-Item -LiteralPath $State.StagedDesktop -Destination $State.DesktopDst
    $State.DesktopActivated = $true
  }

  function Activate-CliPayload {
    param([Parameter(Mandatory)][hashtable]$State)

    if (Test-Path -LiteralPath $State.BinDst) {
      Move-Item -LiteralPath $State.BinDst -Destination $State.BackupBin
      $State.BinBackedUp = $true
    }
    Move-Item -LiteralPath $State.StagedBinLink -Destination $State.BinDst
    $State.BinActivated = $true
    if (Test-Path -LiteralPath $State.LibDst) {
      Move-Item -LiteralPath $State.LibDst -Destination $State.BackupLib
      $State.LibBackedUp = $true
    }
    Move-Item -LiteralPath $State.StagedLibLink -Destination $State.LibDst
    $State.LibActivated = $true
  }

  function Restore-CliPayload {
    param([Parameter(Mandatory)][hashtable]$State)

    $restoreErrors = @()
    if ($State.LibActivated) {
      try { Remove-TransactionPath -Path $State.LibDst } catch { $restoreErrors += $_.Exception.Message }
      $State.LibActivated = $false
    }
    if ($State.BinActivated) {
      try { Remove-TransactionPath -Path $State.BinDst } catch { $restoreErrors += $_.Exception.Message }
      $State.BinActivated = $false
    }
    if ($State.BinBackedUp -and (Test-Path -LiteralPath $State.BackupBin)) {
      try {
        Move-Item -LiteralPath $State.BackupBin -Destination $State.BinDst
        $State.BinBackedUp = $false
      } catch { $restoreErrors += $_.Exception.Message }
    }
    if ($State.LibBackedUp -and (Test-Path -LiteralPath $State.BackupLib)) {
      try {
        Move-Item -LiteralPath $State.BackupLib -Destination $State.LibDst
        $State.LibBackedUp = $false
      } catch { $restoreErrors += $_.Exception.Message }
    }
    if ($restoreErrors.Count -gt 0) {
      throw ($restoreErrors -join '; ')
    }
  }

  function Restore-DesktopPayload {
    param([Parameter(Mandatory)][hashtable]$State)

    $restoreErrors = @()
    if ($State.DesktopActivated) {
      try { Remove-TransactionPath -Path $State.DesktopDst } catch { $restoreErrors += $_.Exception.Message }
      $State.DesktopActivated = $false
    }
    if ($State.DesktopBackedUp -and (Test-Path -LiteralPath $State.BackupDesktop)) {
      try {
        Move-Item -LiteralPath $State.BackupDesktop -Destination $State.DesktopDst
        $State.DesktopBackedUp = $false
      } catch { $restoreErrors += $_.Exception.Message }
    }
    if ($restoreErrors.Count -gt 0) {
      throw ($restoreErrors -join '; ')
    }
  }

  function Remove-TransactionBackup {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
      Remove-TransactionPath -Path $Path
    } catch {
      Write-Warning "The new install is active, but the previous payload could not be removed: $Path"
    }
  }

  try {
    $lockPaths = @()
    if ($cli) { $lockPaths += Join-Path $InstallRoot '.quotabot-install.lock' }
    if ($desktop) { $lockPaths += Join-Path $InstallRoot '.quotabot-desktop-install.lock' }
    $lockPaths = [string[]]$lockPaths
    [Array]::Sort($lockPaths, [StringComparer]::OrdinalIgnoreCase)
    foreach ($lockPath in $lockPaths) {
      try {
        $installLock = [IO.File]::Open(
          $lockPath,
          [IO.FileMode]::OpenOrCreate,
          [IO.FileAccess]::ReadWrite,
          [IO.FileShare]::None
        )
        $locks += [pscustomobject]@{ Path = $lockPath; Stream = $installLock }
      } catch {
        throw 'Another quotabot install is already activating a bundle. Re-run after it finishes.'
      }
    }

    if ($cli) { Stage-CliPayload -State $cli }
    if ($desktop) { Stage-DesktopPayload -State $desktop }

    # Make the desktop visible first. If any CLI switch then fails, rollback
    # restores both stable payloads before either install lock is released.
    if ($desktop) { Activate-DesktopPayload -State $desktop }
    if ($cli) { Activate-CliPayload -State $cli }
    $activationSucceeded = $true
  } catch {
    $installError = $_.Exception.Message
    $rollbackErrors = @()
    if ($cli) {
      try { Restore-CliPayload -State $cli } catch { $rollbackErrors += $_.Exception.Message }
    }
    if ($desktop) {
      try { Restore-DesktopPayload -State $desktop } catch { $rollbackErrors += $_.Exception.Message }
    }
    $rollbackComplete = $rollbackErrors.Count -eq 0
    if ($rollbackComplete) {
      if ($cli) {
        Remove-TransactionPath -Path $cli.StagedBinLink
        Remove-TransactionPath -Path $cli.StagedLibLink
        Remove-TransactionPath -Path $cli.StagedPayload
        if ($cli.VersionStaged) { Remove-TransactionPath -Path $cli.VersionRoot }
      }
      if ($desktop) { Remove-TransactionPath -Path $desktop.StagedDesktop }
    }
    if (-not $rollbackComplete) {
      throw "Install failed and rollback was incomplete. Recovery payloads remain under $InstallRoot. Original error: $installError. Rollback error: $($rollbackErrors -join '; ')"
    }
    throw "Could not replace the existing install; it was left intact or restored. Close any running quotabot process and re-run. ($installError)"
  } finally {
    if ($activationSucceeded) {
      if ($cli) {
        Remove-TransactionBackup -Path $cli.BackupBin
        Remove-TransactionBackup -Path $cli.BackupLib
        foreach ($candidate in Get-ChildItem -LiteralPath $cli.VersionsRoot -Directory -Force -ErrorAction SilentlyContinue) {
          if ($candidate.FullName -ine $cli.VersionRoot) {
            if ($candidate.LinkType -or $candidate.Name -notmatch '^[0-9a-f]{32}$') {
              Write-Warning "Skipping an unexpected entry under the CLI generation directory: $($candidate.FullName)"
              continue
            }
            try {
              $candidateExe = Join-Path $candidate.FullName 'bin\quotabot.exe'
              if (Test-Path -LiteralPath $candidateExe -PathType Leaf) {
                $exclusiveExe = [IO.File]::Open(
                  $candidateExe,
                  [IO.FileMode]::Open,
                  [IO.FileAccess]::ReadWrite,
                  [IO.FileShare]::None
                )
                $exclusiveExe.Dispose()
              }
              Remove-TransactionPath -Path $candidate.FullName
            } catch {
              Write-Warning "The old CLI generation is still in use and could not be removed: $($candidate.FullName)"
            }
          }
        }
      }
      if ($desktop) { Remove-TransactionBackup -Path $desktop.BackupDesktop }
    }
    foreach ($lock in @($locks)) {
      try { $lock.Stream.Dispose() } catch {}
    }
    foreach ($lock in @($locks)) {
      Remove-Item -LiteralPath $lock.Path -Force -ErrorAction SilentlyContinue
    }
  }
}

function Install-QuotabotPayload {
  param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$InstallRoot
  )

  Invoke-QuotabotPayloadTransaction `
    -CliSourceRoot $SourceRoot `
    -InstallRoot $InstallRoot
}

function Install-QuotabotDesktopPayload {
  param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$InstallRoot
  )

  Invoke-QuotabotPayloadTransaction `
    -DesktopSourceRoot $SourceRoot `
    -InstallRoot $InstallRoot
}

function Install-QuotabotPayloadPair {
  param(
    [Parameter(Mandatory)][string]$CliSourceRoot,
    [Parameter(Mandatory)][string]$DesktopSourceRoot,
    [Parameter(Mandatory)][string]$InstallRoot
  )

  Invoke-QuotabotPayloadTransaction `
    -CliSourceRoot $CliSourceRoot `
    -DesktopSourceRoot $DesktopSourceRoot `
    -InstallRoot $InstallRoot
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

function Restart-QuotabotDesktopAfterSetup {
  param(
    [Parameter(Mandatory)][string]$InstalledAppExe,
    [string[]]$RestartCandidates = @(),
    [Parameter(Mandatory)][bool]$DesktopActivated
  )

  $orderedCandidates = if ($DesktopActivated) {
    @($InstalledAppExe) + @($RestartCandidates)
  } else {
    @($RestartCandidates) + @($InstalledAppExe)
  }
  $restartExe = $orderedCandidates |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -Unique |
    Select-Object -First 1
  if (-not $restartExe) { return $null }

  if (@(Get-RunningDesktopApp $restartExe).Count -eq 0) {
    Start-Process `
      -FilePath $restartExe `
      -WorkingDirectory (Split-Path -Parent $restartExe) | Out-Null
  }
  return $restartExe
}

Write-Step 'Locating the Dart toolchain'
$dartBin = Resolve-DartBin
$env:Path = "$dartBin;$dartBin\cache\dart-sdk\bin;$env:Path"
$dartVer = (& dart --version 2>&1 | Select-Object -First 1)
Write-Ok $dartVer

Write-Step 'Building the quotabot CLI'
Push-Location $collector
try {
  & dart pub get --enforce-lockfile | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "dart pub get failed with exit code $LASTEXITCODE" }
  & (Join-Path $scriptDir 'package-cli.ps1')
} finally { Pop-Location }

$asset = Get-QuotabotWindowsReleaseArchive -RepositoryRoot $root -Architecture $windowsArch
if (-not (Test-Path -LiteralPath $asset)) {
  throw "CLI build did not produce $(Split-Path -Leaf $asset) in release/"
}

Write-Step "Preparing the CLI for $installRoot"
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
  if ($CliOnly -or $NoApp) {
    Write-Step "Installing the CLI to $installRoot"
    Install-QuotabotPayload -SourceRoot $extractPath -InstallRoot $installRoot
  } else {
    $desktopInstallRoot = Join-Path $installRoot 'desktop'
    $installedAppExe = Join-Path $desktopInstallRoot 'quotabot.exe'
    $legacyBuiltAppExe = Resolve-BuiltAppExe
    $restartRequested = $false
    $restartCandidates = @()
    $desktopActivated = $false
    $desktopFailure = $null
    try {
      # An app launched from the build tree can lock files Flutter must replace.
      # Stop only that legacy case before the build. The normally installed app
      # remains running until both candidate payloads are complete.
      $runningBuildApp = @(Get-RunningDesktopApp $legacyBuiltAppExe)
      if ($runningBuildApp.Count -gt 0) {
        $restartRequested = $true
        $restartCandidates += @($runningBuildApp | ForEach-Object { $_.Path })
        Write-Step 'Stopping the desktop app running from the build tree'
        foreach ($proc in $runningBuildApp) {
          Stop-Process -Id $proc.Id -Force
        }
        foreach ($proc in $runningBuildApp) {
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
        & flutter pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed with exit code $LASTEXITCODE" }
        & flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed with exit code $LASTEXITCODE" }
      } finally { Pop-Location }

      $builtAppExe = Resolve-BuiltAppExe
      if (-not $builtAppExe) { throw "Desktop build finished, but quotabot.exe was not found under app\build\windows" }

      $runningApp = @(
        @($installedAppExe, $builtAppExe) |
          Where-Object { $_ } |
          Sort-Object -Unique |
          ForEach-Object { Get-RunningDesktopApp $_ } |
          Sort-Object Id -Unique
      )
      if ($runningApp.Count -gt 0) {
        $restartRequested = $true
        $restartCandidates += @($runningApp | ForEach-Object { $_.Path })
        Write-Step 'Stopping the running desktop app for activation'
        foreach ($proc in $runningApp) {
          Stop-Process -Id $proc.Id -Force
        }
        foreach ($proc in $runningApp) {
          try { Wait-Process -Id $proc.Id -Timeout 10 } catch {}
        }
      }

      Write-Step 'Activating the CLI and desktop app'
      Install-QuotabotPayloadPair `
        -CliSourceRoot $extractPath `
        -DesktopSourceRoot (Split-Path -Parent $builtAppExe) `
        -InstallRoot $installRoot
      $desktopActivated = $true

      Write-Step 'Creating the Desktop shortcut'
      & (Join-Path $scriptDir 'create-shortcut.ps1') -ExePath $installedAppExe
    } catch {
      $desktopFailure = $_
      throw
    } finally {
      if ($restartRequested) {
        try {
          $restartExe = Restart-QuotabotDesktopAfterSetup `
            -InstalledAppExe $installedAppExe `
            -RestartCandidates $restartCandidates `
            -DesktopActivated $desktopActivated
          if ($restartExe) {
            if ($desktopActivated) {
              Write-Ok 'Restarted the newly installed desktop app after setup'
            } else {
              Write-Ok 'Restarted the prior desktop app after setup failed'
            }
          } elseif ($desktopFailure) {
            Write-Warning 'Setup failed after stopping the desktop app, but no runnable prior or installed executable remains.'
          } else {
            throw 'Desktop setup stopped a running app but could not find an executable to restart.'
          }
        } catch {
          if ($desktopFailure) {
            Write-Warning "Setup failed and the previously running desktop app could not be restarted: $($_.Exception.Message)"
          } else {
            throw
          }
        }
      }
    }
  }
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
Write-Ok 'Installed quotabot.exe'

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
