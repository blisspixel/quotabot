<#
.SYNOPSIS
  Runs the full quotabot contributor gate on Windows.

.DESCRIPTION
  Uses the shared space-safe Dart and Flutter invocation path, so native-asset
  hooks work when the installed Flutter SDK is under a path containing spaces.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'windows-space-safe-dart.ps1')

function Write-Gate([string]$Message) {
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

$toolchain = Enable-QuotabotSpaceSafeDart `
  -PreferredRoot $root `
  -IncludeFlutter
try {
  if ($toolchain.Kind -ne 'verbatim') {
    Write-Host "Using space-free Dart path $($toolchain.DartExecutable) ($($toolchain.Kind))."
  }

  Write-Gate 'Repository policy and release consistency'
  Push-Location $root
  try {
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('-m', 'ruff', 'check', '.')
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('-m', 'ruff', 'format', '--check', '.')
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('-m', 'unittest', 'discover', '-s', 'tools', '-p', 'test_*.py')
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('tools/check_release_version.py')
    foreach ($test in @(
        'test-windows-space-safe-dart.ps1',
        'test-windows-architecture.ps1',
        'test-install-transaction.ps1',
        'test-package-pair.ps1')) {
      & (Join-Path $scriptDir $test)
      if ($LASTEXITCODE -ne 0) {
        throw "$test failed with exit code $LASTEXITCODE"
      }
    }
  } finally {
    Pop-Location
  }

  Write-Gate 'Collector format, analysis, tests, and coverage'
  Push-Location (Join-Path $root 'collector')
  try {
    Invoke-QuotabotDart `
      -State $toolchain `
      -Arguments @('pub', 'get', '--enforce-lockfile')
    Invoke-QuotabotDart `
      -State $toolchain `
      -Arguments @('format', '--set-exit-if-changed', '.')
    Invoke-QuotabotDart -State $toolchain -Arguments @('analyze')
    Invoke-QuotabotDart `
      -State $toolchain `
      -Arguments @('test', '--coverage=coverage')
    Invoke-QuotabotDart -State $toolchain -Arguments @(
      'run',
      'coverage:format_coverage',
      '--lcov',
      '--check-ignore',
      '--in=coverage',
      '--out=coverage/lcov.info',
      '--packages=.dart_tool/package_config.json',
      '--report-on=lib'
    )
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('../tools/check_lcov.py', 'coverage/lcov.info', '90')
  } finally {
    Pop-Location
  }

  Write-Gate 'Desktop format, analysis, tests, and coverage'
  Push-Location (Join-Path $root 'app')
  try {
    Invoke-QuotabotFlutter `
      -State $toolchain `
      -Arguments @('pub', 'get', '--enforce-lockfile')
    Invoke-QuotabotDart `
      -State $toolchain `
      -Arguments @('format', '--set-exit-if-changed', 'lib', 'test')
    Invoke-QuotabotFlutter `
      -State $toolchain `
      -Arguments @('analyze', '--no-pub')
    Invoke-QuotabotFlutter `
      -State $toolchain `
      -Arguments @('test', '--no-pub', '--coverage')
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('../tools/check_lcov.py', 'coverage/lcov.info', '80')
  } finally {
    Pop-Location
  }

  Write-Gate 'MCP client snippets'
  Push-Location (Join-Path $root 'integrations\mcp_clients')
  try {
    Invoke-CheckedCommand -Command 'npm' -Arguments @('ci')
    Invoke-CheckedCommand -Command 'npm' -Arguments @('run', 'typecheck')
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('-m', 'unittest', 'test_mcp_client_snippets.py')
  } finally {
    Pop-Location
  }

  Write-Gate 'LiteLLM router and proxy integration'
  Push-Location (Join-Path $root 'integrations\litellm')
  $originalProxyTest = $env:QUOTABOT_RUN_LITELLM_PROXY_TEST
  try {
    Invoke-CheckedCommand `
      -Command 'python' `
      -Arguments @('-m', 'pip', 'install', '--require-hashes', '-r', 'requirements.txt')
    $env:QUOTABOT_RUN_LITELLM_PROXY_TEST = '1'
    Invoke-CheckedCommand -Command 'python' -Arguments @(
      '-m',
      'unittest',
      'test_quotabot_router.py',
      'test_quotabot_proxy_integration.py'
    )
  } finally {
    if ($null -eq $originalProxyTest) {
      Remove-Item Env:QUOTABOT_RUN_LITELLM_PROXY_TEST -ErrorAction SilentlyContinue
    } else {
      $env:QUOTABOT_RUN_LITELLM_PROXY_TEST = $originalProxyTest
    }
    Pop-Location
  }

  Write-Host 'All quotabot Windows gates passed.' -ForegroundColor Green
} finally {
  Disable-QuotabotSpaceSafeDart -State $toolchain
}
