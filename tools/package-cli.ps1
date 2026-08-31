# Builds the quotabot CLI release asset for the current Windows machine.
# Produces release/quotabot-windows-<arch>.zip and a matching .sha256 sidecar.

param(
  [switch]$NoArchive,
  [switch]$PackageOnly
)

$ErrorActionPreference = 'Stop'

if ($NoArchive -and $PackageOnly) {
  throw '-NoArchive and -PackageOnly cannot be combined.'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$collectorDir = Join-Path $root 'collector'
$releaseDir = Join-Path $root 'release'
$buildDir = Join-Path $collectorDir 'build\quotabot_cli_release'
. (Join-Path $scriptDir 'windows-architecture.ps1')
. (Join-Path $scriptDir 'package-pair.ps1')

$arch = Get-QuotabotWindowsArchitecture
$asset = "quotabot-windows-$arch.zip"
$out = Join-Path $releaseDir $asset
$sidecar = "$out.sha256"
$bundle = Join-Path $buildDir 'bundle'
$packagedExe = Join-Path $bundle 'bin\quotabot.exe'
$packagedLib = Join-Path $bundle 'lib'

if (-not $PackageOnly) {
  . (Join-Path $scriptDir 'windows-space-safe-dart.ps1')
  $spaceSafe = Enable-QuotabotSpaceSafeDart -PreferredRoot $root
  try {
    $dart = $spaceSafe.DartExecutable
    if ($spaceSafe.Kind -ne 'verbatim') {
      Write-Host "Using space-free Dart path $dart ($($spaceSafe.Kind)) because the toolchain path contains spaces."
    }

    Push-Location $collectorDir
    try {
      & $dart pub get --enforce-lockfile
      if ($LASTEXITCODE -ne 0) {
        throw "dart pub get failed with exit code $LASTEXITCODE"
      }
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
  } finally {
    Disable-QuotabotSpaceSafeDart -State $spaceSafe
  }

  $builtExe = Join-Path $bundle 'bin\collect.exe'
  if (-not (Test-Path -LiteralPath $builtExe -PathType Leaf)) {
    throw "CLI build did not produce $builtExe"
  }
  Move-Item -LiteralPath $builtExe -Destination $packagedExe -Force
}

if (-not (Test-Path -LiteralPath $packagedExe -PathType Leaf)) {
  if ($PackageOnly) {
    throw "Package-only mode requires the existing normalized CLI executable: $packagedExe"
  }
  throw "CLI build did not produce $packagedExe"
}

# Bundle the exact installer implementations used by `quotabot update`. The
# complete CLI archive and its checksum authenticate these scripts before they
# are activated, so self-update never executes the mutable main-branch copy.
New-Item -ItemType Directory -Force -Path $packagedLib | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'install.ps1') -Destination $packagedLib -Force
Copy-Item -LiteralPath (Join-Path $root 'install.sh') -Destination $packagedLib -Force

if ($NoArchive) {
  Write-Host "CLI bundle ready: $bundle"
  return
}

New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
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
