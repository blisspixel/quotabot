# Creates or refreshes a Desktop shortcut to the built quotabot desktop app.
# Points at the Release build and uses the app's own icon. Re-run after a build
# to repoint the shortcut. Build first with: cd app; flutter build windows --release
param(
  [string]$ExePath
)

$ErrorActionPreference = 'Stop'

# Flutter builds under build\windows\<arch>\runner\Release (x64 or arm64); pick
# whichever exists rather than assuming x64, so the shortcut works on ARM64.
if (-not $ExePath) {
  foreach ($arch in @('x64', 'arm64')) {
    $candidate = Join-Path $PSScriptRoot "..\app\build\windows\$arch\runner\Release\quotabot.exe"
    if (Test-Path -LiteralPath $candidate) { $ExePath = $candidate; break }
  }
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
