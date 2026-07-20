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

function New-TestDesktopPayload {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Version
  )

  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  Set-Content -LiteralPath (Join-Path $Root 'quotabot.exe') -Value $Version -NoNewline
  Set-Content -LiteralPath (Join-Path $Root 'plugin.dll') -Value "$Version plugin" -NoNewline
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

function Get-JunctionTarget {
  param([Parameter(Mandatory)][string]$Path)

  $item = Get-Item -LiteralPath $Path -Force
  if ($item.LinkType -ne 'Junction') {
    throw "Expected a junction at $Path, got $($item.LinkType)"
  }
  return [IO.Path]::GetFullPath([string]$item.Target)
}

function Assert-ActivatedPayload {
  param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$Expected
  )

  $binTarget = Get-JunctionTarget -Path (Join-Path $InstallRoot 'bin')
  $libTarget = Get-JunctionTarget -Path (Join-Path $InstallRoot 'lib')
  $binGeneration = Split-Path -Parent $binTarget
  $libGeneration = Split-Path -Parent $libTarget
  if ($binGeneration -ine $libGeneration) {
    throw "The active bin and lib junctions name different generations: $binTarget, $libTarget"
  }
  Assert-Content -Path (Join-Path $binTarget 'quotabot.exe') -Expected $Expected
  Assert-Content -Path (Join-Path $libTarget 'sqlite3.dll') -Expected $Expected
  Assert-Content -Path (Join-Path $InstallRoot 'bin\quotabot.exe') -Expected $Expected
  Assert-Content -Path (Join-Path $InstallRoot 'lib\sqlite3.dll') -Expected $Expected
  return $binGeneration
}

function Assert-DesktopPayload {
  param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][string]$Expected
  )

  Assert-Content `
    -Path (Join-Path $InstallRoot 'desktop\quotabot.exe') `
    -Expected $Expected
  Assert-Content `
    -Path (Join-Path $InstallRoot 'desktop\plugin.dll') `
    -Expected "$Expected plugin"
}

function Assert-NoTransactionDebris {
  param([Parameter(Mandatory)][string]$InstallRoot)

  $debris = @(Get-ChildItem -LiteralPath $InstallRoot -Force | Where-Object {
      $_.Name -like '.quotabot-*'
    })
  if ($debris.Count -gt 0) {
    throw "Transaction debris remains under ${InstallRoot}: $($debris.Name -join ', ')"
  }
}

function Assert-VersionCount {
  param(
    [Parameter(Mandatory)][string]$InstallRoot,
    [Parameter(Mandatory)][int]$Expected
  )

  $versionsRoot = Join-Path $InstallRoot 'cli-versions'
  $actual = @(Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction SilentlyContinue).Count
  if ($actual -ne $Expected) {
    throw "Expected $Expected CLI generation(s) under $versionsRoot, got $actual"
  }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "quotabot-install-transaction-$([guid]::NewGuid())"
try {
  New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
  foreach ($relativeScript in @('install.ps1', 'tools\setup.ps1')) {
    $scriptPath = Join-Path $repositoryRoot $relativeScript
    if ($relativeScript -eq 'tools\setup.ps1') {
      Import-InstallFunction `
        -Path $scriptPath `
        -Name 'Invoke-QuotabotPayloadTransaction'
    }
    Import-InstallFunction -Path $scriptPath
    $label = [IO.Path]::GetFileNameWithoutExtension($relativeScript)

    $successSource = Join-Path $testRoot "$label-success-source"
    $successInstall = Join-Path $testRoot "$label-success-install"
    New-TestPayload -Root $successSource -Version 'new'
    New-TestPayload -Root $successInstall -Version 'old'
    New-Item -ItemType Directory -Force -Path (Join-Path $successInstall 'manual') | Out-Null
    Set-Content -LiteralPath (Join-Path $successInstall 'manual\sentinel') -Value 'keep' -NoNewline

    Install-QuotabotPayload -SourceRoot $successSource -InstallRoot $successInstall
    $firstGeneration = Assert-ActivatedPayload -InstallRoot $successInstall -Expected 'new'
    Assert-Content -Path (Join-Path $successInstall 'manual\sentinel') -Expected 'keep'
    Assert-NoTransactionDebris -InstallRoot $successInstall
    Assert-VersionCount -InstallRoot $successInstall -Expected 1

    $secondSource = Join-Path $testRoot "$label-second-source"
    New-TestPayload -Root $secondSource -Version 'newer'
    Install-QuotabotPayload -SourceRoot $secondSource -InstallRoot $successInstall
    $secondGeneration = Assert-ActivatedPayload -InstallRoot $successInstall -Expected 'newer'
    if ($secondGeneration -ieq $firstGeneration) {
      throw "$relativeScript did not activate a distinct complete generation"
    }
    if (Test-Path -LiteralPath $firstGeneration) {
      throw "$relativeScript did not remove the unreferenced first generation"
    }
    Assert-VersionCount -InstallRoot $successInstall -Expected 1

    $failureSource = Join-Path $testRoot "$label-failure-source"
    New-TestPayload -Root $failureSource -Version 'candidate'
    $script:activeBinPath = Join-Path $successInstall 'bin'
    $script:activeLibPath = Join-Path $successInstall 'lib'
    $script:observedCompleteCandidate = $false

    function Move-Item {
      param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Force
      )
      if (
        $LiteralPath -eq $script:activeLibPath -and
        (Split-Path -Leaf $Destination) -like '.quotabot-lib-previous-*'
      ) {
        $candidateBin = Get-JunctionTarget -Path $script:activeBinPath
        $candidateGeneration = Split-Path -Parent $candidateBin
        Assert-Content -Path (Join-Path $candidateBin 'quotabot.exe') -Expected 'candidate'
        Assert-Content -Path (Join-Path $candidateGeneration 'lib\sqlite3.dll') -Expected 'candidate'
        Assert-Content -Path (Join-Path $script:activeLibPath 'sqlite3.dll') -Expected 'newer'
        $script:observedCompleteCandidate = $true
        throw 'Injected failure between bin and compatibility lib activation'
      }
      Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }

    $failed = $false
    $failureMessage = $null
    try {
      Install-QuotabotPayload -SourceRoot $failureSource -InstallRoot $successInstall
    } catch {
      $failed = $true
      $failureMessage = $_.Exception.Message
      if ($_.Exception.Message -notmatch 'left intact or restored') {
        throw
      }
    } finally {
      Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
    }
    if (-not $failed) {
      throw "$relativeScript did not surface the injected activation failure"
    }
    if (-not $script:observedCompleteCandidate) {
      throw "$relativeScript did not expose the candidate as one complete target generation. Failure: $failureMessage"
    }
    $restoredGeneration = Assert-ActivatedPayload -InstallRoot $successInstall -Expected 'newer'
    if ($restoredGeneration -ine $secondGeneration) {
      throw "$relativeScript did not restore the previously active generation"
    }
    Assert-Content -Path (Join-Path $successInstall 'manual\sentinel') -Expected 'keep'
    Assert-NoTransactionDebris -InstallRoot $successInstall
    Assert-VersionCount -InstallRoot $successInstall -Expected 1

    # A second installer must fail before staging and leave the active
    # generation untouched.
    $lockPath = Join-Path $successInstall '.quotabot-install.lock'
    $heldLock = [IO.File]::Open(
      $lockPath,
      [IO.FileMode]::OpenOrCreate,
      [IO.FileAccess]::ReadWrite,
      [IO.FileShare]::None
    )
    $lockRejected = $false
    try {
      Install-QuotabotPayload -SourceRoot $failureSource -InstallRoot $successInstall
    } catch {
      $lockRejected = $_.Exception.Message -match 'Another quotabot install'
      if (-not $lockRejected) { throw }
    } finally {
      $heldLock.Dispose()
      Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $lockRejected) {
      throw "$relativeScript did not reject a concurrent installer"
    }
    $null = Assert-ActivatedPayload -InstallRoot $successInstall -Expected 'newer'
    Assert-NoTransactionDebris -InstallRoot $successInstall
    Assert-VersionCount -InstallRoot $successInstall -Expected 1

    # A planted generation-directory junction must fail closed. Otherwise the
    # installer could stage or prune payloads outside its install root.
    $poisonSource = Join-Path $testRoot "$label-poison-source"
    $poisonInstall = Join-Path $testRoot "$label-poison-install"
    $poisonOutside = Join-Path $testRoot "$label-poison-outside"
    New-TestPayload -Root $poisonSource -Version 'poison-candidate'
    New-Item -ItemType Directory -Force -Path $poisonInstall, $poisonOutside | Out-Null
    Set-Content `
      -LiteralPath (Join-Path $poisonOutside 'sentinel') `
      -Value 'keep' `
      -NoNewline
    New-Item `
      -ItemType Junction `
      -Path (Join-Path $poisonInstall 'cli-versions') `
      -Target $poisonOutside | Out-Null

    $poisonRejected = $false
    try {
      Install-QuotabotPayload `
        -SourceRoot $poisonSource `
        -InstallRoot $poisonInstall
    } catch {
      $poisonRejected = $_.Exception.Message -match 'link as the CLI generation directory'
      if (-not $poisonRejected) { throw }
    }
    if (-not $poisonRejected) {
      throw "$relativeScript accepted a linked CLI generation directory"
    }
    Assert-Content -Path (Join-Path $poisonOutside 'sentinel') -Expected 'keep'
    if (@(Get-ChildItem -LiteralPath $poisonOutside -Force).Count -ne 1) {
      throw "$relativeScript wrote through the linked CLI generation directory"
    }
    Assert-NoTransactionDebris -InstallRoot $poisonInstall

    # Model a reader that has opened the old executable while activation
    # occurs. Cleanup must retain that complete generation until the reader
    # releases it, then a later idempotent install removes the orphan.
    $heldExePath = Join-Path $secondGeneration 'bin\quotabot.exe'
    $heldExe = [IO.File]::Open(
      $heldExePath,
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      [IO.FileShare]::Read
    )
    try {
      $concurrentSource = Join-Path $testRoot "$label-concurrent-source"
      New-TestPayload -Root $concurrentSource -Version 'concurrent'
      Install-QuotabotPayload -SourceRoot $concurrentSource -InstallRoot $successInstall
      $null = Assert-ActivatedPayload -InstallRoot $successInstall -Expected 'concurrent'
      Assert-Content -Path (Join-Path $secondGeneration 'lib\sqlite3.dll') -Expected 'newer'
      Assert-VersionCount -InstallRoot $successInstall -Expected 2
    } finally {
      $heldExe.Dispose()
    }

    $finalSource = Join-Path $testRoot "$label-final-source"
    New-TestPayload -Root $finalSource -Version 'final'
    Install-QuotabotPayload -SourceRoot $finalSource -InstallRoot $successInstall
    $null = Assert-ActivatedPayload -InstallRoot $successInstall -Expected 'final'
    Assert-VersionCount -InstallRoot $successInstall -Expected 1
    Assert-NoTransactionDebris -InstallRoot $successInstall
  }

  $setupScript = Join-Path $repositoryRoot 'tools\setup.ps1'
  Import-InstallFunction -Path $setupScript -Name 'Install-QuotabotDesktopPayload'
  Import-InstallFunction -Path $setupScript -Name 'Install-QuotabotPayloadPair'
  Import-InstallFunction `
    -Path $setupScript `
    -Name 'Restart-QuotabotDesktopAfterSetup'

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

  # Full source setup must stage both payloads before changing either stable
  # target. An incomplete desktop build therefore leaves the installed CLI and
  # desktop on the same prior version.
  $pairInstall = Join-Path $testRoot 'paired-install'
  $pairOldCli = Join-Path $testRoot 'paired-old-cli'
  $pairOldDesktop = Join-Path $testRoot 'paired-old-desktop'
  $pairCandidateCli = Join-Path $testRoot 'paired-candidate-cli'
  $pairCandidateDesktop = Join-Path $testRoot 'paired-candidate-desktop'
  New-TestPayload -Root $pairOldCli -Version 'old'
  New-TestDesktopPayload -Root $pairOldDesktop -Version 'old'
  New-TestPayload -Root $pairCandidateCli -Version 'candidate'
  New-TestDesktopPayload -Root $pairCandidateDesktop -Version 'candidate'
  Install-QuotabotPayload -SourceRoot $pairOldCli -InstallRoot $pairInstall
  Install-QuotabotDesktopPayload `
    -SourceRoot $pairOldDesktop `
    -InstallRoot $pairInstall
  New-Item -ItemType Directory -Force -Path (Join-Path $pairInstall 'manual') | Out-Null
  Set-Content `
    -LiteralPath (Join-Path $pairInstall 'manual\sentinel') `
    -Value 'keep' `
    -NoNewline
  $pairOldGeneration = Assert-ActivatedPayload `
    -InstallRoot $pairInstall `
    -Expected 'old'
  Assert-DesktopPayload -InstallRoot $pairInstall -Expected 'old'

  $incompleteDesktop = Join-Path $testRoot 'paired-incomplete-desktop'
  New-Item -ItemType Directory -Force -Path $incompleteDesktop | Out-Null
  Set-Content `
    -LiteralPath (Join-Path $incompleteDesktop 'plugin.dll') `
    -Value 'candidate plugin' `
    -NoNewline
  $buildFailureSurfaced = $false
  try {
    Install-QuotabotPayloadPair `
      -CliSourceRoot $pairCandidateCli `
      -DesktopSourceRoot $incompleteDesktop `
      -InstallRoot $pairInstall
  } catch {
    $buildFailureSurfaced = $_.Exception.Message -match 'left intact or restored'
    if (-not $buildFailureSurfaced) { throw }
  }
  if (-not $buildFailureSurfaced) {
    throw 'An incomplete desktop build did not fail the paired transaction.'
  }
  $afterBuildFailure = Assert-ActivatedPayload `
    -InstallRoot $pairInstall `
    -Expected 'old'
  if ($afterBuildFailure -ine $pairOldGeneration) {
    throw 'Desktop build validation changed the active CLI generation.'
  }
  Assert-DesktopPayload -InstallRoot $pairInstall -Expected 'old'
  Assert-NoTransactionDebris -InstallRoot $pairInstall
  Assert-VersionCount -InstallRoot $pairInstall -Expected 1

  # A failure switching the desktop happens before the CLI switch. The staged
  # CLI generation is removed and both prior stable targets remain active.
  $script:pairDesktopTarget = Join-Path $pairInstall 'desktop'
  function Move-Item {
    param(
      [Parameter(Mandatory)][string]$LiteralPath,
      [Parameter(Mandatory)][string]$Destination,
      [switch]$Force
    )
    if (
      $Destination -eq $script:pairDesktopTarget -and
      (Split-Path -Leaf $LiteralPath) -like '.quotabot-desktop-new-*'
    ) {
      throw 'Injected paired desktop activation failure'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
  }
  $pairedDesktopFailureSurfaced = $false
  try {
    Install-QuotabotPayloadPair `
      -CliSourceRoot $pairCandidateCli `
      -DesktopSourceRoot $pairCandidateDesktop `
      -InstallRoot $pairInstall
  } catch {
    $pairedDesktopFailureSurfaced = $_.Exception.Message -match 'left intact or restored'
    if (-not $pairedDesktopFailureSurfaced) { throw }
  } finally {
    Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
  }
  if (-not $pairedDesktopFailureSurfaced) {
    throw 'The paired desktop activation failure was not surfaced.'
  }
  $null = Assert-ActivatedPayload -InstallRoot $pairInstall -Expected 'old'
  Assert-DesktopPayload -InstallRoot $pairInstall -Expected 'old'
  Assert-NoTransactionDebris -InstallRoot $pairInstall
  Assert-VersionCount -InstallRoot $pairInstall -Expected 1

  # The desktop switches first. Inject a later CLI switch failure and prove the
  # transaction restores that already-switched desktop as well as the CLI.
  $script:pairActiveLib = Join-Path $pairInstall 'lib'
  $script:observedPairedDesktopCandidate = $false
  function Move-Item {
    param(
      [Parameter(Mandatory)][string]$LiteralPath,
      [Parameter(Mandatory)][string]$Destination,
      [switch]$Force
    )
    if (
      $LiteralPath -eq $script:pairActiveLib -and
      (Split-Path -Leaf $Destination) -like '.quotabot-lib-previous-*'
    ) {
      Assert-DesktopPayload -InstallRoot $pairInstall -Expected 'candidate'
      $script:observedPairedDesktopCandidate = $true
      throw 'Injected CLI activation failure after desktop activation'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
  }
  $pairedCliFailureSurfaced = $false
  try {
    Install-QuotabotPayloadPair `
      -CliSourceRoot $pairCandidateCli `
      -DesktopSourceRoot $pairCandidateDesktop `
      -InstallRoot $pairInstall
  } catch {
    $pairedCliFailureSurfaced = $_.Exception.Message -match 'left intact or restored'
    if (-not $pairedCliFailureSurfaced) { throw }
  } finally {
    Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
  }
  if (-not $pairedCliFailureSurfaced -or -not $script:observedPairedDesktopCandidate) {
    throw 'The paired CLI failure did not occur after desktop activation.'
  }
  $null = Assert-ActivatedPayload -InstallRoot $pairInstall -Expected 'old'
  Assert-DesktopPayload -InstallRoot $pairInstall -Expected 'old'
  Assert-Content -Path (Join-Path $pairInstall 'manual\sentinel') -Expected 'keep'
  Assert-NoTransactionDebris -InstallRoot $pairInstall
  Assert-VersionCount -InstallRoot $pairInstall -Expected 1

  Install-QuotabotPayloadPair `
    -CliSourceRoot $pairCandidateCli `
    -DesktopSourceRoot $pairCandidateDesktop `
    -InstallRoot $pairInstall
  $pairCandidateGeneration = Assert-ActivatedPayload `
    -InstallRoot $pairInstall `
    -Expected 'candidate'
  if ($pairCandidateGeneration -ieq $pairOldGeneration) {
    throw 'The successful pair did not activate a new CLI generation.'
  }
  Assert-DesktopPayload -InstallRoot $pairInstall -Expected 'candidate'
  Assert-Content -Path (Join-Path $pairInstall 'manual\sentinel') -Expected 'keep'
  Assert-NoTransactionDebris -InstallRoot $pairInstall
  Assert-VersionCount -InstallRoot $pairInstall -Expected 1

  # Either lock blocks the pair before staging. Acquired locks are released in
  # deterministic path order and neither stable payload changes.
  foreach ($lockName in @('.quotabot-desktop-install.lock', '.quotabot-install.lock')) {
    $lockPath = Join-Path $pairInstall $lockName
    $heldLock = [IO.File]::Open(
      $lockPath,
      [IO.FileMode]::OpenOrCreate,
      [IO.FileAccess]::ReadWrite,
      [IO.FileShare]::None
    )
    $pairLockRejected = $false
    try {
      Install-QuotabotPayloadPair `
        -CliSourceRoot $pairOldCli `
        -DesktopSourceRoot $pairOldDesktop `
        -InstallRoot $pairInstall
    } catch {
      $pairLockRejected = $_.Exception.Message -match 'Another quotabot install'
      if (-not $pairLockRejected) { throw }
    } finally {
      $heldLock.Dispose()
      Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $pairLockRejected) {
      throw "The paired transaction did not honor $lockName."
    }
    $null = Assert-ActivatedPayload -InstallRoot $pairInstall -Expected 'candidate'
    Assert-DesktopPayload -InstallRoot $pairInstall -Expected 'candidate'
    Assert-NoTransactionDebris -InstallRoot $pairInstall
  }

  # Setup failure restarts the exact prior process path first. Successful
  # activation restarts the newly installed stable desktop path first.
  $priorBuildRoot = Join-Path $testRoot 'paired-prior-build'
  New-TestDesktopPayload -Root $priorBuildRoot -Version 'prior-build'
  $priorBuildExe = Join-Path $priorBuildRoot 'quotabot.exe'
  $installedPairExe = Join-Path $pairInstall 'desktop\quotabot.exe'
  $script:startedDesktopPaths = @()
  function Get-RunningDesktopApp { param($exePath) return @() }
  function Start-Process {
    param(
      [Parameter(Mandatory)][string]$FilePath,
      [Parameter(Mandatory)][string]$WorkingDirectory
    )
    $script:startedDesktopPaths += $FilePath
  }
  try {
    $failureRestart = Restart-QuotabotDesktopAfterSetup `
      -InstalledAppExe $installedPairExe `
      -RestartCandidates @($priorBuildExe) `
      -DesktopActivated $false
    if ($failureRestart -ine $priorBuildExe) {
      throw 'Failed setup did not select the prior desktop process path.'
    }
    $successRestart = Restart-QuotabotDesktopAfterSetup `
      -InstalledAppExe $installedPairExe `
      -RestartCandidates @($priorBuildExe) `
      -DesktopActivated $true
    if ($successRestart -ine $installedPairExe) {
      throw 'Successful setup did not select the installed desktop path.'
    }
  } finally {
    Remove-Item Function:\Get-RunningDesktopApp -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
  }
  if ($script:startedDesktopPaths.Count -ne 2 -or
      $script:startedDesktopPaths[0] -ine $priorBuildExe -or
      $script:startedDesktopPaths[1] -ine $installedPairExe) {
    throw "Unexpected desktop restart sequence: $($script:startedDesktopPaths -join ', ')"
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
