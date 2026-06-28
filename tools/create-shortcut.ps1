# Creates or refreshes a Desktop shortcut to the built quotabot desktop app.
# Points at the Release build and uses the app's own icon. Re-run after a build
# to repoint the shortcut. Build first with: cd app; flutter build windows --release
param(
  [string]$ExePath = (Join-Path $PSScriptRoot '..\app\build\windows\x64\runner\Release\quotabot.exe')
)

$ErrorActionPreference = 'Stop'

$resolved = Resolve-Path -LiteralPath $ExePath -ErrorAction SilentlyContinue
if (-not $resolved) {
  throw "quotabot.exe not found at '$ExePath'. Build it first: cd app; flutter build windows --release"
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
