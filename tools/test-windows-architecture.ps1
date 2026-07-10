$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-architecture.ps1')

if ((Get-QuotabotWindowsArchitecture -Architecture X64) -ne 'x64') {
  throw 'X64 architecture mapping failed.'
}
if ((Get-QuotabotWindowsArchitecture -Architecture Arm64) -ne 'arm64') {
  throw 'Arm64 architecture mapping failed.'
}
try {
  Get-QuotabotWindowsArchitecture -Architecture Arm | Out-Null
  throw 'Unsupported architecture did not fail.'
} catch {
  if ($_.Exception.Message -notmatch '^Unsupported Windows architecture:') {
    throw
  }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "quotabot-architecture-$([guid]::NewGuid())"
try {
  $appRoot = Join-Path $root 'app'
  $x64 = Join-Path $appRoot 'build\windows\x64\runner\Release\quotabot.exe'
  $arm64 = Join-Path $appRoot 'build\windows\arm64\runner\Release\quotabot.exe'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $x64), (Split-Path -Parent $arm64) | Out-Null
  New-Item -ItemType File -Force -Path $x64, $arm64 | Out-Null

  $resolvedArm64 = Get-QuotabotWindowsBuiltAppExecutable -AppRoot $appRoot -Architecture arm64
  if ($resolvedArm64 -ne (Resolve-Path -LiteralPath $arm64).Path) {
    throw 'ARM64 app selection used the wrong build output.'
  }
  $resolvedX64 = Get-QuotabotWindowsBuiltAppExecutable -AppRoot $appRoot -Architecture x64
  if ($resolvedX64 -ne (Resolve-Path -LiteralPath $x64).Path) {
    throw 'X64 app selection used the wrong build output.'
  }

  $archive = Get-QuotabotWindowsReleaseArchive -RepositoryRoot $root -Architecture arm64
  if ($archive -ne (Join-Path $root 'release\quotabot-windows-arm64.zip')) {
    throw 'ARM64 archive selection used the wrong path.'
  }
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($root)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolvedRoot).StartsWith('quotabot-architecture-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host 'Windows architecture helper tests passed.'
