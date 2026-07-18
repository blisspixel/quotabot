# Builds the quotabot CLI release asset for the current Windows machine.
# Produces release/quotabot-windows-<arch>.zip and a matching .sha256 sidecar.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$collectorDir = Join-Path $root 'collector'
$releaseDir = Join-Path $root 'release'
$buildDir = Join-Path $collectorDir 'build\quotabot_cli_release'
. (Join-Path $scriptDir 'windows-architecture.ps1')
. (Join-Path $scriptDir 'package-pair.ps1')

$dart = (Get-Command dart -ErrorAction SilentlyContinue).Source
if (-not $dart) {
  $flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
  if ($flutter) {
    $candidate = Join-Path (Split-Path -Parent $flutter) 'dart.exe'
    if (Test-Path -LiteralPath $candidate) {
      $dart = $candidate
    }
  }
}
if (-not $dart) {
  throw "dart not found on PATH. Install Flutter or Dart and add it to PATH."
}

$arch = Get-QuotabotWindowsArchitecture

New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$asset = "quotabot-windows-$arch.zip"
$out = Join-Path $releaseDir $asset
$sidecar = "$out.sha256"

Push-Location $collectorDir
try {
  if (Test-Path -LiteralPath $buildDir) {
    Remove-Item -LiteralPath $buildDir -Recurse -Force
  }
  & $dart build cli --target=bin\collect.dart --output=$buildDir
  if ($LASTEXITCODE -ne 0) {
    throw "dart build cli failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

$bundle = Join-Path $buildDir 'bundle'
$builtExe = Join-Path $bundle 'bin\collect.exe'
$packagedExe = Join-Path $bundle 'bin\quotabot.exe'
if (-not (Test-Path -LiteralPath $builtExe)) {
  throw "CLI build did not produce $builtExe"
}
Move-Item -LiteralPath $builtExe -Destination $packagedExe -Force

$packageWorkspace = Join-Path $releaseDir ".quotabot-package-$([guid]::NewGuid())"
$temporaryOut = Join-Path $packageWorkspace $asset
$temporarySidecar = "$temporaryOut.sha256"
New-Item -ItemType Directory -Force -Path $packageWorkspace | Out-Null
try {
  Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $temporaryOut
  $hash = (Get-FileHash -Algorithm SHA256 $temporaryOut).Hash.ToLowerInvariant()
  Set-Content -LiteralPath $temporarySidecar -Value "$hash  $asset" -NoNewline

  # Activate both complete files as one rollback-protected package pair.
  Publish-QuotabotPackagePair `
    -TemporaryArchive $temporaryOut `
    -TemporarySidecar $temporarySidecar `
    -Archive $out `
    -Sidecar $sidecar `
    -Workspace $packageWorkspace
} finally {
  if (Test-Path -LiteralPath (Join-Path $packageWorkspace '.preserve')) {
    Write-Warning "Package recovery files were preserved in $packageWorkspace"
  } else {
    Remove-Item -LiteralPath $packageWorkspace -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "CLI asset ready: $out"
Write-Host "Checksum: $sidecar"
Write-Host "SHA256: $hash"
