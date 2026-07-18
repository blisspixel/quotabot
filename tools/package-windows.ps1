# Build the native Windows desktop bundle and optionally archive it.

param(
  [switch]$NoArchive
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$appDir = Join-Path $root 'app'
$releaseRoot = Join-Path $root 'release'
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
  $hash = Get-FileHash -Algorithm SHA256 $exe
  Write-Host "SHA256: $($hash.Hash.ToLowerInvariant())"
} else {
  throw 'Build did not produce expected exe.'
}

if (-not $NoArchive) {
  New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
  $asset = 'quotabot-windows-x64-desktop.zip'
  $archive = Join-Path $releaseRoot $asset
  $sidecar = "$archive.sha256"
  Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue

  Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $archive
  $archiveHash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
  Set-Content -LiteralPath $sidecar -Value "$archiveHash  $asset" -NoNewline

  Write-Host "Archive ready: $archive"
  Write-Host "Checksum: $sidecar"
  Write-Host "Archive SHA256: $archiveHash"
}
