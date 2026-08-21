$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "quotabot-doctor-test-$([guid]::NewGuid())"
try {
  New-Item -ItemType Directory -Path $testRoot | Out-Null
  $success = Join-Path $testRoot 'doctor-success.cmd'
  $failure = Join-Path $testRoot 'doctor-failure.cmd'
  Set-Content -LiteralPath $success -Encoding ASCII -Value @(
    '@echo off',
    'echo {"schema":"quotabot.v1","providers":[]}',
    'exit /b 0'
  )
  Set-Content -LiteralPath $failure -Encoding ASCII -Value @(
    '@echo off',
    'echo {"schema":"quotabot.v1","providers":[]}',
    'exit /b 65'
  )

  & (Join-Path $PSScriptRoot 'verify-doctor.ps1') -Executable $success

  $failedClosed = $false
  try {
    & (Join-Path $PSScriptRoot 'verify-doctor.ps1') -Executable $failure
  } catch {
    $failedClosed = $_.Exception.Message -match 'exited with code 65'
    if (-not $failedClosed) { throw }
  }
  if (-not $failedClosed) {
    throw 'Doctor verification accepted valid JSON from a process that exited 65.'
  }
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (
    $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $resolvedRoot).StartsWith('quotabot-doctor-test-', [StringComparison]::Ordinal)
  ) {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host 'Windows doctor verification tests passed.'
