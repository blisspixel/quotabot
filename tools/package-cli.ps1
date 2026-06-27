# Builds the quotabot CLI release asset for the current Windows machine.
# Produces release/quotabot-windows-<arch>.exe and a matching .sha256 sidecar.

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$collectorDir = Join-Path $root 'collector'
$releaseDir = Join-Path $root 'release'

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

$arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
  'X64' { 'x64' }
  'Arm64' { 'arm64' }
  default { throw "Unsupported architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)" }
}

New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$asset = "quotabot-windows-$arch.exe"
$out = Join-Path $releaseDir $asset

Push-Location $collectorDir
try {
  & $dart compile exe bin\collect.dart -o $out
  if ($LASTEXITCODE -ne 0) {
    throw "dart compile failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

$hash = (Get-FileHash -Algorithm SHA256 $out).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$out.sha256" -Value "$hash  $asset" -NoNewline

Write-Host "CLI asset ready: $out"
Write-Host "Checksum: $out.sha256"
Write-Host "SHA256: $hash"
