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
  Import-InstallFunction -Path $setupScript -Name 'Get-QuotabotSourceReleaseTag'
  Import-InstallFunction -Path $setupScript -Name 'Start-QuotabotAfterSetup'
  Import-InstallFunction `
    -Path $setupScript `
    -Name 'Restart-QuotabotDesktopAfterSetup'

  $sourceReleaseTag = Get-QuotabotSourceReleaseTag `
    -AppRoot (Join-Path $repositoryRoot 'app')
  $appManifestVersion = @(
    Get-Content -LiteralPath (Join-Path $repositoryRoot 'app\pubspec.yaml') |
      Where-Object { $_ -match '^version:\s+' } |
      Select-Object -First 1
  )[0] -replace '^version:\s+', ''
  $expectedSourceReleaseTag = "v$(($appManifestVersion -split '\+')[0])"
  if ($sourceReleaseTag -ne $expectedSourceReleaseTag) {
    throw "Source release tag lost its preview identifier: $sourceReleaseTag"
  }

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
    function Get-RunningDesktopApp {
      param($exePath)
      if ($exePath -ieq $installedPairExe) {
        return @([pscustomobject]@{ Id = 123; Path = $installedPairExe })
      }
      return @()
    }
    function Write-Step { param([string]$Message) }
    function Write-Ok { param([string]$Message) }
    $installRoot = $pairInstall
    $desktopSkipped = $false
    $NoApp = $false
    $startCount = $script:startedDesktopPaths.Count
    Start-QuotabotAfterSetup `
      -CliExecutable (Join-Path $pairInstall 'bin\quotabot.exe') `
      -AllowDesktop
    if ($script:startedDesktopPaths.Count -ne $startCount) {
      throw 'Setup launched a duplicate desktop process.'
    }
  } finally {
    Remove-Item Function:\Get-RunningDesktopApp -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
    Remove-Item Function:\Write-Step -ErrorAction SilentlyContinue
    Remove-Item Function:\Write-Ok -ErrorAction SilentlyContinue
  }
  if ($script:startedDesktopPaths.Count -ne 2 -or
      $script:startedDesktopPaths[0] -ine $priorBuildExe -or
      $script:startedDesktopPaths[1] -ine $installedPairExe) {
    throw "Unexpected desktop restart sequence: $($script:startedDesktopPaths -join ', ')"
  }

  # Uninstall stops only processes running from the install root, removes every
  # executable generation, and preserves config when purge is not requested.
  $uninstallScript = Join-Path $repositoryRoot 'uninstall.ps1'
  Import-InstallFunction -Path $uninstallScript -Name 'Write-Step'
  Import-InstallFunction -Path $uninstallScript -Name 'Write-Ok'
  Import-InstallFunction -Path $uninstallScript -Name 'Invoke-QuotabotUninstall'
  $uninstallRoot = Join-Path $testRoot 'uninstall-install'
  $uninstallGeneration = Join-Path $uninstallRoot 'cli-versions\0123456789abcdef0123456789abcdef'
  $uninstallDesktop = Join-Path $uninstallRoot 'desktop'
  $uninstallSentinel = Join-Path $uninstallRoot 'manual\sentinel'
  $uninstallShortcut = Join-Path $testRoot 'uninstall-shortcut.lnk'
  New-Item -ItemType Directory -Force -Path `
    (Join-Path $uninstallGeneration 'bin'), `
    (Join-Path $uninstallGeneration 'lib'), `
    $uninstallDesktop, `
    (Split-Path -Parent $uninstallSentinel) | Out-Null
  Set-Content -LiteralPath $uninstallSentinel -Value 'keep' -NoNewline
  Set-Content -LiteralPath (Join-Path $uninstallGeneration 'lib\sqlite3.dll') -Value 'library' -NoNewline
  Set-Content -LiteralPath (Join-Path $uninstallDesktop 'plugin.dll') -Value 'desktop' -NoNewline
  Set-Content -LiteralPath $uninstallShortcut -Value 'shortcut' -NoNewline
  $installedExecutable = Join-Path $uninstallGeneration 'bin\quotabot.exe'
  $unrelatedRoot = Join-Path $testRoot 'unrelated-process'
  New-Item -ItemType Directory -Force -Path $unrelatedRoot | Out-Null
  $unrelatedExecutable = Join-Path $unrelatedRoot 'quotabot.exe'
  Copy-Item -LiteralPath "$env:SystemRoot\System32\ping.exe" -Destination $installedExecutable
  Copy-Item -LiteralPath "$env:SystemRoot\System32\ping.exe" -Destination $unrelatedExecutable
  $installedProcess = Start-Process `
    -FilePath $installedExecutable `
    -ArgumentList @('-n', '30', '127.0.0.1') `
    -PassThru
  $unrelatedProcess = Start-Process `
    -FilePath $unrelatedExecutable `
    -ArgumentList @('-n', '30', '127.0.0.1') `
    -PassThru
  try {
    Start-Sleep -Milliseconds 250
    Invoke-QuotabotUninstall `
      -InstallRoot $uninstallRoot `
      -DesktopShortcut $uninstallShortcut
    if (Get-Process -Id $installedProcess.Id -ErrorAction SilentlyContinue) {
      throw 'Uninstall did not stop the installed quotabot process.'
    }
    if (-not (Get-Process -Id $unrelatedProcess.Id -ErrorAction SilentlyContinue)) {
      throw 'Uninstall stopped an unrelated quotabot process.'
    }
    foreach ($removedName in @('bin', 'lib', 'cli-versions', 'desktop')) {
      if (Test-Path -LiteralPath (Join-Path $uninstallRoot $removedName)) {
        throw "Uninstall retained $removedName."
      }
    }
    Assert-Content -Path $uninstallSentinel -Expected 'keep'
    if (Test-Path -LiteralPath $uninstallShortcut) {
      throw 'Uninstall retained the desktop shortcut.'
    }
  } finally {
    Stop-Process -Id $installedProcess.Id -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $unrelatedProcess.Id -Force -ErrorAction SilentlyContinue
  }

  # An independently held generation file cannot be deleted. The uninstaller
  # must fail and name the retained payload rather than reporting success.
  $retainedRoot = Join-Path $testRoot 'uninstall-retained'
  $retainedFile = Join-Path $retainedRoot 'cli-versions\fedcba9876543210fedcba9876543210\bin\quotabot.exe'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $retainedFile) | Out-Null
  Set-Content -LiteralPath $retainedFile -Value 'locked' -NoNewline
  $heldPayload = [IO.File]::Open(
    $retainedFile,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read
  )
  $retainedFailed = $false
  try {
    try {
      Invoke-QuotabotUninstall `
        -InstallRoot $retainedRoot `
        -DesktopShortcut (Join-Path $testRoot 'missing-shortcut.lnk')
    } catch {
      $retainedFailed = $_.Exception.Message -match 'uninstall was incomplete' -and
        $_.Exception.Message -match 'cli-versions'
      if (-not $retainedFailed) { throw }
    }
  } finally {
    $heldPayload.Dispose()
  }
  if (-not $retainedFailed) {
    throw 'Uninstall accepted a retained CLI generation store.'
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
