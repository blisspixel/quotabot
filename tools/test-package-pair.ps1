$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'package-pair.ps1')

function Assert-PackageContent {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Expected
  )

  $actual = Get-Content -LiteralPath $Path -Raw
  if ($actual -cne $Expected) {
    throw "Expected '$Expected' at $Path, got '$actual'"
  }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "quotabot-package-pair-$([guid]::NewGuid())"
try {
  New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

  $successWorkspace = Join-Path $testRoot 'success-workspace'
  $successArchive = Join-Path $testRoot 'success.zip'
  $successSidecar = "$successArchive.sha256"
  $successTemporaryArchive = Join-Path $successWorkspace 'success.zip'
  $successTemporarySidecar = "$successTemporaryArchive.sha256"
  New-Item -ItemType Directory -Force -Path $successWorkspace | Out-Null
  Set-Content -LiteralPath $successArchive -Value 'old archive' -NoNewline
  Set-Content -LiteralPath $successSidecar -Value 'old checksum' -NoNewline
  Set-Content -LiteralPath $successTemporaryArchive -Value 'new archive' -NoNewline
  Set-Content -LiteralPath $successTemporarySidecar -Value 'new checksum' -NoNewline

  Publish-QuotabotPackagePair `
    -TemporaryArchive $successTemporaryArchive `
    -TemporarySidecar $successTemporarySidecar `
    -Archive $successArchive `
    -Sidecar $successSidecar `
    -Workspace $successWorkspace
  Assert-PackageContent -Path $successArchive -Expected 'new archive'
  Assert-PackageContent -Path $successSidecar -Expected 'new checksum'

  $failureWorkspace = Join-Path $testRoot 'failure-workspace'
  $failureArchive = Join-Path $testRoot 'failure.zip'
  $failureSidecar = "$failureArchive.sha256"
  $failureTemporaryArchive = Join-Path $failureWorkspace 'failure.zip'
  $failureTemporarySidecar = "$failureTemporaryArchive.sha256"
  New-Item -ItemType Directory -Force -Path $failureWorkspace | Out-Null
  Set-Content -LiteralPath $failureArchive -Value 'old archive' -NoNewline
  Set-Content -LiteralPath $failureSidecar -Value 'old checksum' -NoNewline
  Set-Content -LiteralPath $failureTemporaryArchive -Value 'new archive' -NoNewline
  Set-Content -LiteralPath $failureTemporarySidecar -Value 'new checksum' -NoNewline

  function Move-Item {
    param(
      [Parameter(Mandatory)][string]$LiteralPath,
      [Parameter(Mandatory)][string]$Destination,
      [switch]$Force
    )
    if (
      $LiteralPath -eq $failureTemporarySidecar -and
      $Destination -eq $failureSidecar
    ) {
      throw 'Injected checksum activation failure'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
  }

  $failed = $false
  try {
    Publish-QuotabotPackagePair `
      -TemporaryArchive $failureTemporaryArchive `
      -TemporarySidecar $failureTemporarySidecar `
      -Archive $failureArchive `
      -Sidecar $failureSidecar `
      -Workspace $failureWorkspace
  } catch {
    $failed = $true
    if ($_.Exception.Message -notmatch 'previous archive and checksum were restored') {
      throw
    }
  } finally {
    Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
  }
  if (-not $failed) {
    throw 'The injected checksum activation failure was not surfaced.'
  }

  Assert-PackageContent -Path $failureArchive -Expected 'old archive'
  Assert-PackageContent -Path $failureSidecar -Expected 'old checksum'
  if (Test-Path -LiteralPath "$failureArchive.quotabot-package.lock") {
    throw 'The failed package activation left its writer lock behind.'
  }

  $lockWorkspace = Join-Path $testRoot 'lock-workspace'
  $lockArchive = Join-Path $testRoot 'locked.zip'
  $lockSidecar = "$lockArchive.sha256"
  $lockTemporaryArchive = Join-Path $lockWorkspace 'locked.zip'
  $lockTemporarySidecar = "$lockTemporaryArchive.sha256"
  New-Item -ItemType Directory -Force -Path $lockWorkspace | Out-Null
  Set-Content -LiteralPath $lockArchive -Value 'old archive' -NoNewline
  Set-Content -LiteralPath $lockSidecar -Value 'old checksum' -NoNewline
  Set-Content -LiteralPath $lockTemporaryArchive -Value 'new archive' -NoNewline
  Set-Content -LiteralPath $lockTemporarySidecar -Value 'new checksum' -NoNewline
  $lockPath = "$lockArchive.quotabot-package.lock"
  $heldLock = [IO.File]::Open(
    $lockPath,
    [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None
  )
  try {
    $lockRejected = $false
    try {
      Publish-QuotabotPackagePair `
        -TemporaryArchive $lockTemporaryArchive `
        -TemporarySidecar $lockTemporarySidecar `
        -Archive $lockArchive `
        -Sidecar $lockSidecar `
        -Workspace $lockWorkspace
    } catch {
      $lockRejected = $_.Exception.Message -match 'already publishing'
    }
    if (-not $lockRejected) {
      throw 'A concurrent package publisher was not rejected.'
    }
    Assert-PackageContent -Path $lockArchive -Expected 'old archive'
    Assert-PackageContent -Path $lockSidecar -Expected 'old checksum'
  } finally {
    $heldLock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
  }
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (
    $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $resolvedRoot).StartsWith('quotabot-package-pair-', [StringComparison]::Ordinal)
  ) {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host 'Windows package pair transaction tests passed.'
