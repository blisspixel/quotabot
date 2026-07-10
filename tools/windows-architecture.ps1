$ErrorActionPreference = 'Stop'

function Get-QuotabotWindowsArchitecture {
  param(
    [System.Runtime.InteropServices.Architecture]$Architecture =
      [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  )

  switch ($Architecture) {
    'X64' { return 'x64' }
    'Arm64' { return 'arm64' }
    default { throw "Unsupported Windows architecture: $Architecture" }
  }
}

function Get-QuotabotWindowsReleaseArchive {
  param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot,
    [string]$Architecture = (Get-QuotabotWindowsArchitecture)
  )

  Join-Path $RepositoryRoot "release\quotabot-windows-$Architecture.zip"
}

function Get-QuotabotWindowsBuiltAppExecutable {
  param(
    [Parameter(Mandatory)]
    [string]$AppRoot,
    [string]$Architecture = (Get-QuotabotWindowsArchitecture)
  )

  $candidate = Join-Path $AppRoot "build\windows\$Architecture\runner\Release\quotabot.exe"
  $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue
  if ($resolved) { return $resolved.Path }
  return $null
}
