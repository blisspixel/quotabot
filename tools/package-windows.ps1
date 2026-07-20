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
. (Join-Path $scriptDir 'windows-architecture.ps1')
. (Join-Path $scriptDir 'package-pair.ps1')

$windowsArch = Get-QuotabotWindowsArchitecture
if ($windowsArch -ne 'x64') {
  throw "Windows desktop release packaging currently supports x64 only, not $windowsArch. Refusing to label a different build as x64."
}

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
  & $flutter pub get --enforce-lockfile
  if ($LASTEXITCODE -ne 0) {
    throw "flutter pub get failed with exit code $LASTEXITCODE"
  }
  & $flutter build windows --release --no-pub
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
  $packageWorkspace = Join-Path $releaseRoot ".quotabot-package-$([guid]::NewGuid())"
  $temporaryArchive = Join-Path $packageWorkspace $asset
  $temporarySidecar = "$temporaryArchive.sha256"
  New-Item -ItemType Directory -Force -Path $packageWorkspace | Out-Null
  try {
    Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $temporaryArchive
    $archiveHash = (Get-FileHash -Algorithm SHA256 $temporaryArchive).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $temporarySidecar -Value "$archiveHash  $asset" -NoNewline

    # Activate both complete files as one rollback-protected package pair.
    Publish-QuotabotPackagePair `
      -TemporaryArchive $temporaryArchive `
      -TemporarySidecar $temporarySidecar `
      -Archive $archive `
      -Sidecar $sidecar `
      -Workspace $packageWorkspace
  } finally {
    if (Test-Path -LiteralPath (Join-Path $packageWorkspace '.preserve')) {
      Write-Warning "Package recovery files were preserved in $packageWorkspace"
    } else {
      Remove-Item -LiteralPath $packageWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Write-Host "Archive ready: $archive"
  Write-Host "Checksum: $sidecar"
  Write-Host "Archive SHA256: $archiveHash"
}
