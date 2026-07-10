# Builds the quotabot CLI release asset for the current Windows machine.
# Produces release/quotabot-windows-<arch>.zip and a matching .sha256 sidecar.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$collectorDir = Join-Path $root 'collector'
$releaseDir = Join-Path $root 'release'
$buildDir = Join-Path $collectorDir 'build\quotabot_cli_release'
. (Join-Path $scriptDir 'windows-architecture.ps1')

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

Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $out -Force

$hash = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLowerInvariant()
Set-Content -LiteralPath $sidecar -Value "$hash  $asset" -NoNewline

Write-Host "CLI asset ready: $out"
Write-Host "Checksum: $sidecar"
Write-Host "SHA256: $hash"
