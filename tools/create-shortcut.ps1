# Creates or refreshes a Desktop shortcut to the built quotabot desktop app.
# Points at the Release build and uses the app's own icon. Re-run after a build
# to repoint the shortcut. Build first with: cd app; flutter build windows --release
param(
  [string]$ExePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

if (-not $ExePath) {
  $appRoot = Join-Path $PSScriptRoot '..\app'
  $ExePath = Get-QuotabotWindowsBuiltAppExecutable -AppRoot $appRoot
}

$resolved = if ($ExePath) { Resolve-Path -LiteralPath $ExePath -ErrorAction SilentlyContinue } else { $null }
if (-not $resolved) {
  throw "quotabot.exe not found. Build it first: cd app; flutter build windows --release"
}
$exe = $resolved.Path

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop 'quotabot.lnk'

$ws = New-Object -ComObject WScript.Shell
$shortcut = $ws.CreateShortcut($lnkPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = Split-Path -Parent $exe
$shortcut.IconLocation = "$exe,0"
$shortcut.Description = 'quotabot - AI subscription quota tracker'
$shortcut.Save()

Write-Host "Desktop shortcut written: $lnkPath -> $exe"
