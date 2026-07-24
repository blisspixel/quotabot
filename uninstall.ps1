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

$installRoot = Join-Path $env:LOCALAPPDATA 'quotabot'
$installDir = Join-Path $installRoot 'bin'

Write-Step 'Removing CLI installations and PATH entry'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
  $kept = @($userPath -split ';' | Where-Object { $_ -and $_ -ne $installDir })
  $newPath = $kept -join ';'
  if ($userPath -ne $newPath) {
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Ok "Removed $installDir from your PATH"
  } else {
    Write-Ok "PATH already clean"
  }
}

foreach ($name in @('bin', 'lib')) {
  $path = Join-Path $installRoot $name
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (-not $item) { continue }
  if ($item.LinkType) {
    Remove-Item -LiteralPath $path -Force
  } else {
    Remove-Item -LiteralPath $path -Recurse -Force
  }
}
Remove-Item -LiteralPath (Join-Path $installRoot 'cli-versions') -Recurse -Force -ErrorAction SilentlyContinue
Write-Ok 'Removed CLI binaries'

Write-Step 'Removing desktop installations'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'quotabot.lnk'
if (Test-Path $desktopShortcut) {
  Remove-Item -LiteralPath $desktopShortcut -Force
  Write-Ok 'Removed Desktop shortcut'
}

$desktopRoot = Join-Path $installRoot 'desktop'
if (Test-Path $desktopRoot) {
  # Stop process if running
  $procs = Get-Process -Name 'quotabot' -ErrorAction SilentlyContinue
  if ($procs) {
    Write-Ok 'Stopping running quotabot processes...'
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
  Remove-Item -LiteralPath $desktopRoot -Recurse -Force -ErrorAction SilentlyContinue
  Write-Ok 'Removed desktop app'
}

if ($Purge) {
  Write-Step 'Purging metadata, cache, and logs'
  $cacheDir = Join-Path $installRoot 'cache'
  if (Test-Path $cacheDir) {
    Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Ok 'Purged quotabot data directory'
}

Write-Host ''
Write-Host 'quotabot has been successfully uninstalled.' -ForegroundColor Green
Write-Host 'Restart your terminal for PATH changes to take effect.'
