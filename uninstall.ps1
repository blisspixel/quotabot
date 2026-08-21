<#
.SYNOPSIS
  Uninstalls the quotabot CLI and desktop app on Windows.

.DESCRIPTION
  Removes the CLI and desktop app installations, cleans up the user PATH entry,
  and deletes the Desktop shortcut. It does not delete metadata, cache, or logs
  unless the -Purge switch is provided.
#>
[CmdletBinding()]
param(
  [switch]$Purge
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Invoke-QuotabotUninstall {
  param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$DesktopShortcut,
    [switch]$Purge
  )

  $resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
  $installPrefix = "$resolvedInstallRoot\"
  $installDir = Join-Path $resolvedInstallRoot 'bin'
  $removalErrors = [Collections.Generic.List[string]]::new()
  $installRootItem = Get-Item -LiteralPath $resolvedInstallRoot -Force -ErrorAction SilentlyContinue
  if ($installRootItem -and $installRootItem.LinkType) {
    throw "Refusing to uninstall through a linked install root: $resolvedInstallRoot"
  }

  function Test-InstalledProcessPath {
    param([string]$Path)

    if (-not $Path) { return $false }
    try {
      $resolved = [IO.Path]::GetFullPath($Path)
      return $resolved.StartsWith(
        $installPrefix,
        [StringComparison]::OrdinalIgnoreCase
      )
    } catch {
      return $false
    }
  }

  function Remove-InstallPayloadPath {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to remove a payload outside the quotabot install root: $resolved"
    }
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    try {
      if ($item.LinkType) {
        Remove-Item -LiteralPath $resolved -Force -ErrorAction Stop
      } else {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
      }
    } catch {
      $removalErrors.Add("${resolved}: $($_.Exception.Message)")
    }
  }

  Write-Step 'Stopping installed quotabot processes'
  $installedProcesses = @(
    Get-Process -Name 'quotabot' -ErrorAction SilentlyContinue |
      Where-Object {
        try { Test-InstalledProcessPath -Path $_.Path } catch { $false }
      }
  )
  if ($installedProcesses.Count -gt 0) {
    foreach ($process in $installedProcesses) {
      try {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
      } catch {
        $removalErrors.Add("process $($process.Id): $($_.Exception.Message)")
      }
    }
    foreach ($process in $installedProcesses) {
      try { Wait-Process -Id $process.Id -Timeout 10 -ErrorAction Stop } catch {
        if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
          $removalErrors.Add("process $($process.Id) did not stop")
        }
      }
    }
    Write-Ok "Stopped $($installedProcesses.Count) installed process(es)"
  } else {
    Write-Ok 'No installed quotabot process is running'
  }

  Write-Step 'Removing CLI installations and PATH entry'
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath) {
    $kept = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $installDir })
    $newPath = $kept -join ';'
    if ($userPath -ne $newPath) {
      [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
      Write-Ok "Removed $installDir from your PATH"
    } else {
      Write-Ok 'PATH already clean'
    }
  }

  $payloadNames = @('bin', 'lib', 'cli-versions', 'desktop')
  foreach ($name in $payloadNames) {
    Remove-InstallPayloadPath -Path (Join-Path $resolvedInstallRoot $name)
  }
  foreach ($lockName in @('.quotabot-install.lock', '.quotabot-desktop-install.lock')) {
    Remove-InstallPayloadPath -Path (Join-Path $resolvedInstallRoot $lockName)
  }
  $transactionPatterns = @(
    '.quotabot-payload-new-*',
    '.quotabot-bin-link-new-*',
    '.quotabot-lib-link-new-*',
    '.quotabot-bin-previous-*',
    '.quotabot-lib-previous-*',
    '.quotabot-desktop-new-*',
    '.quotabot-desktop-previous-*'
  )
  foreach ($candidate in Get-ChildItem -LiteralPath $resolvedInstallRoot -Force -ErrorAction SilentlyContinue) {
    if ($transactionPatterns | Where-Object { $candidate.Name -like $_ }) {
      Remove-InstallPayloadPath -Path $candidate.FullName
    }
  }
  Write-Ok 'CLI and desktop payload removal attempted'

  if (Test-Path -LiteralPath $DesktopShortcut) {
    try {
      Remove-Item -LiteralPath $DesktopShortcut -Force -ErrorAction Stop
      Write-Ok 'Removed Desktop shortcut'
    } catch {
      $removalErrors.Add("${DesktopShortcut}: $($_.Exception.Message)")
    }
  }

  if ($Purge) {
    Write-Step 'Purging metadata, cache, and logs'
    # Remove the whole per-user data root, not only the cache. quotabot also
    # stores OAuth grants under auth\, plus profiles, manual entries, leases,
    # loopback tokens, and analytics recovery bundles.
    if (Test-Path -LiteralPath $resolvedInstallRoot) {
      try {
        Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force -ErrorAction Stop
      } catch {
        $removalErrors.Add("${resolvedInstallRoot}: $($_.Exception.Message)")
      }
    }
  }

  $retained = [Collections.Generic.List[string]]::new()
  if ($Purge) {
    if (Test-Path -LiteralPath $resolvedInstallRoot) {
      $retained.Add($resolvedInstallRoot)
    }
  } else {
    foreach ($name in $payloadNames) {
      $path = Join-Path $resolvedInstallRoot $name
      if (Test-Path -LiteralPath $path) { $retained.Add($path) }
    }
    foreach ($candidate in Get-ChildItem -LiteralPath $resolvedInstallRoot -Force -ErrorAction SilentlyContinue) {
      if ($transactionPatterns | Where-Object { $candidate.Name -like $_ }) {
        $retained.Add($candidate.FullName)
      }
    }
  }
  if ($retained.Count -gt 0 -or $removalErrors.Count -gt 0) {
    $details = @($removalErrors) + @($retained | ForEach-Object { "retained $_" })
    throw "Quotabot uninstall was incomplete: $($details -join '; ')"
  }
}

$installRoot = Join-Path $env:LOCALAPPDATA 'quotabot'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'quotabot.lnk'
Invoke-QuotabotUninstall `
  -InstallRoot $installRoot `
  -DesktopShortcut $desktopShortcut `
  -Purge:$Purge

Write-Host ''
Write-Host 'quotabot has been successfully uninstalled.' -ForegroundColor Green
Write-Host 'Restart your terminal for PATH changes to take effect.'
