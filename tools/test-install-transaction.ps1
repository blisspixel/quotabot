$ErrorActionPreference = 'Stop'

function Import-InstallFunction {
  param(
    [Parameter(Mandatory)][string]$Path,
    [string]$Name = 'Install-QuotabotPayload'
  )

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $Path,
    [ref]$tokens,
    [ref]$errors
  )
  if ($errors.Count -gt 0) {
    throw "Could not parse $Path"
  }
  $definition = $ast.Find(
    {
      param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $Name
    },
    $true
  )
  if (-not $definition) {
    throw "$Name was not found in $Path"
  }
  $globalDefinition = $definition.Extent.Text -replace (
    "^function\s+$([regex]::Escape($Name))",
    "function global:$Name"
  )
  Invoke-Expression $globalDefinition
}

function New-TestPayload {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Version
  )

  New-Item -ItemType Directory -Force -Path (Join-Path $Root 'bin'), (Join-Path $Root 'lib') | Out-Null
  Set-Content -LiteralPath (Join-Path $Root 'bin\quotabot.exe') -Value $Version -NoNewline
  Set-Content -LiteralPath (Join-Path $Root 'lib\sqlite3.dll') -Value $Version -NoNewline
}

function Assert-Content {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Expected
  )

  $actual = Get-Content -LiteralPath $Path -Raw
  if ($actual -cne $Expected) {
    throw "Expected '$Expected' at $Path, got '$actual'"
  }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "quotabot-install-transaction-$([guid]::NewGuid())"
try {
  New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
  foreach ($relativeScript in @('install.ps1', 'tools\setup.ps1')) {
    $scriptPath = Join-Path $repositoryRoot $relativeScript
    Import-InstallFunction -Path $scriptPath
    $label = [IO.Path]::GetFileNameWithoutExtension($relativeScript)

    $successSource = Join-Path $testRoot "$label-success-source"
    $successInstall = Join-Path $testRoot "$label-success-install"
    New-TestPayload -Root $successSource -Version 'new'
    New-TestPayload -Root $successInstall -Version 'old'
    New-Item -ItemType Directory -Force -Path (Join-Path $successInstall 'manual') | Out-Null
    Set-Content -LiteralPath (Join-Path $successInstall 'manual\sentinel') -Value 'keep' -NoNewline

    Install-QuotabotPayload -SourceRoot $successSource -InstallRoot $successInstall
    Assert-Content -Path (Join-Path $successInstall 'bin\quotabot.exe') -Expected 'new'
    Assert-Content -Path (Join-Path $successInstall 'lib\sqlite3.dll') -Expected 'new'
    Assert-Content -Path (Join-Path $successInstall 'manual\sentinel') -Expected 'keep'
    if (Get-ChildItem -LiteralPath $successInstall -Force | Where-Object { $_.Name -like '.quotabot-*' }) {
      throw "$relativeScript left transaction directories after a successful install"
    }

    $failureSource = Join-Path $testRoot "$label-failure-source"
    $failureInstall = Join-Path $testRoot "$label-failure-install"
    New-TestPayload -Root $failureSource -Version 'new'
    New-TestPayload -Root $failureInstall -Version 'old'
    New-Item -ItemType Directory -Force -Path (Join-Path $failureInstall 'manual') | Out-Null
    Set-Content -LiteralPath (Join-Path $failureInstall 'manual\sentinel') -Value 'keep' -NoNewline
    $script:blockedLibDestination = Join-Path $failureInstall 'lib'

    function Move-Item {
      param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Force
      )
      if (
        $Destination -eq $script:blockedLibDestination -and
        (Split-Path -Leaf $LiteralPath) -like '.quotabot-lib-new-*'
      ) {
        throw 'Injected lib activation failure'
      }
      Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }

    $failed = $false
    try {
      Install-QuotabotPayload -SourceRoot $failureSource -InstallRoot $failureInstall
    } catch {
      $failed = $true
      if ($_.Exception.Message -notmatch 'left intact or restored') {
        throw
      }
    } finally {
      Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
    }
    if (-not $failed) {
      throw "$relativeScript did not surface the injected activation failure"
    }

    Assert-Content -Path (Join-Path $failureInstall 'bin\quotabot.exe') -Expected 'old'
    Assert-Content -Path (Join-Path $failureInstall 'lib\sqlite3.dll') -Expected 'old'
    Assert-Content -Path (Join-Path $failureInstall 'manual\sentinel') -Expected 'keep'
    if (Get-ChildItem -LiteralPath $failureInstall -Force | Where-Object { $_.Name -like '.quotabot-*' }) {
      throw "$relativeScript left transaction directories after rollback"
    }
  }

  $setupScript = Join-Path $repositoryRoot 'tools\setup.ps1'
  Import-InstallFunction -Path $setupScript -Name 'Install-QuotabotDesktopPayload'

  $desktopSource = Join-Path $testRoot 'desktop-success-source'
  $desktopInstall = Join-Path $testRoot 'desktop-success-install'
  New-Item -ItemType Directory -Force -Path $desktopSource, (Join-Path $desktopInstall 'desktop') | Out-Null
  Set-Content -LiteralPath (Join-Path $desktopSource 'quotabot.exe') -Value 'new' -NoNewline
  Set-Content -LiteralPath (Join-Path $desktopSource 'plugin.dll') -Value 'new plugin' -NoNewline
  Set-Content -LiteralPath (Join-Path $desktopInstall 'desktop\quotabot.exe') -Value 'old' -NoNewline
  Install-QuotabotDesktopPayload -SourceRoot $desktopSource -InstallRoot $desktopInstall
  Assert-Content -Path (Join-Path $desktopInstall 'desktop\quotabot.exe') -Expected 'new'
  Assert-Content -Path (Join-Path $desktopInstall 'desktop\plugin.dll') -Expected 'new plugin'

  $desktopFailureSource = Join-Path $testRoot 'desktop-failure-source'
  $desktopFailureInstall = Join-Path $testRoot 'desktop-failure-install'
  New-Item -ItemType Directory -Force -Path $desktopFailureSource, (Join-Path $desktopFailureInstall 'desktop') | Out-Null
  Set-Content -LiteralPath (Join-Path $desktopFailureSource 'quotabot.exe') -Value 'new' -NoNewline
  Set-Content -LiteralPath (Join-Path $desktopFailureInstall 'desktop\quotabot.exe') -Value 'old' -NoNewline
  $script:blockedDesktopDestination = Join-Path $desktopFailureInstall 'desktop'

  function Move-Item {
    param(
      [Parameter(Mandatory)][string]$LiteralPath,
      [Parameter(Mandatory)][string]$Destination,
      [switch]$Force
    )
    if (
      $Destination -eq $script:blockedDesktopDestination -and
      (Split-Path -Leaf $LiteralPath) -like '.quotabot-desktop-new-*'
    ) {
      throw 'Injected desktop activation failure'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
  }

  $desktopFailed = $false
  try {
    Install-QuotabotDesktopPayload `
      -SourceRoot $desktopFailureSource `
      -InstallRoot $desktopFailureInstall
  } catch {
    $desktopFailed = $true
    if ($_.Exception.Message -notmatch 'left intact or restored') {
      throw
    }
  } finally {
    Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
  }
  if (-not $desktopFailed) {
    throw 'The injected desktop activation failure was not surfaced.'
  }
  Assert-Content -Path (Join-Path $desktopFailureInstall 'desktop\quotabot.exe') -Expected 'old'
  if (Get-ChildItem -LiteralPath $desktopFailureInstall -Force | Where-Object { $_.Name -like '.quotabot-*' }) {
    throw 'The desktop install left transaction files after rollback.'
  }
} finally {
  $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (
    $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $resolvedRoot).StartsWith('quotabot-install-transaction-', [StringComparison]::Ordinal)
  ) {
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host 'Windows install transaction tests passed.'
