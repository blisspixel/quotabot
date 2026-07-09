# Simple Windows packaging helper for quotabot (no over-engineering).
# Run from repo root or tools/.
# Builds release and prints the ready-to-distribute exe location.
# For installer, use Inno Setup or MSIX on the output dir.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$appDir = Join-Path $root 'app'
. (Join-Path $scriptDir 'windows-build-prereqs.ps1')

# Find flutter on PATH so this builds on any machine.
$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) { throw "flutter not found on PATH. Install Flutter and add it to PATH." }
$windowsBuildPrereqs = Assert-WindowsDesktopBuildPrereqs
if ($windowsBuildPrereqs) {
  Write-Host "Visual Studio ATL ready: $($windowsBuildPrereqs.VisualStudioPath)"
}

Write-Host 'Building Windows release...'
Push-Location $appDir
try {
  & $flutter build windows --release
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

$releaseDir = Join-Path $appDir 'build\windows\x64\runner\Release'
$exe = Join-Path $releaseDir 'quotabot.exe'

if (Test-Path $exe) {
  Write-Host "Release ready: $exe"
  Write-Host "Bundle (exe + data + dlls) in: $releaseDir"
  Write-Host "Copy the Release folder for portable distribution."
  $hash = Get-FileHash -Algorithm SHA256 $exe
  Write-Host "SHA256: $($hash.Hash.ToLowerInvariant())"
} else {
  Write-Error 'Build did not produce expected exe.'
}
