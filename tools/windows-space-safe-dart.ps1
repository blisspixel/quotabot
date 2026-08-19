$ErrorActionPreference = 'Stop'

# Dart's Windows native-asset hooks invoke cmd.exe without quoting. A toolchain
# path such as C:\Users\Nick Seal\...\dart.exe then fails with
# "'C:\Users\Nick' is not recognized". Junctions, subst drives, and 8.3 names
# are not enough: Dart reports Platform.resolvedExecutable as the long path.
# Mirror the SDK into a directory whose canonical path has no spaces.

function Resolve-QuotabotDartSdkPath {
  $cmd = Get-Command dart -ErrorAction SilentlyContinue
  if ($cmd) {
    $source = $cmd.Source
    if ($source -like '*.bat') {
      $sdk = Join-Path (Split-Path -Parent $source) 'cache\dart-sdk'
      if (Test-Path -LiteralPath (Join-Path $sdk 'bin\dart.exe') -PathType Leaf) {
        return [IO.Path]::GetFullPath($sdk)
      }
    }
    if ($source -like '*.exe') {
      $bin = Split-Path -Parent $source
      $sdk = Split-Path -Parent $bin
      if (Test-Path -LiteralPath (Join-Path $sdk 'bin\dart.exe') -PathType Leaf) {
        return [IO.Path]::GetFullPath($sdk)
      }
    }
  }

  foreach ($candidate in @(
      "$env:LOCALAPPDATA\flutter\bin\cache\dart-sdk",
      "$env:USERPROFILE\flutter\bin\cache\dart-sdk")) {
    if (Test-Path -LiteralPath (Join-Path $candidate 'bin\dart.exe') -PathType Leaf) {
      return [IO.Path]::GetFullPath($candidate)
    }
  }

  throw 'dart not found on PATH. Install Flutter or Dart and add it to PATH.'
}

function Get-QuotabotSpaceFreeParent {
  param([string]$PreferredRoot)

  $parents = @()
  if ($PreferredRoot) {
    $resolved = [IO.Path]::GetFullPath($PreferredRoot)
    if ($resolved -notmatch ' ') {
      $parents += (Join-Path $resolved '.setup-cache')
    }
  }
  $parents += (Join-Path $env:ProgramData 'quotabot-build')
  $parents += (Join-Path $env:SystemDrive 'quotabot-build')

  foreach ($parent in $parents) {
    if (-not $parent -or $parent -match ' ') { continue }
    try {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      return $parent
    } catch {
      continue
    }
  }

  throw 'Unable to create a space-free directory for a Dart SDK mirror. Install the prebuilt CLI with install.ps1, or install Flutter in a path without spaces.'
}

function Copy-QuotabotDirectoryAsHardLinks {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    $target = Join-Path $Destination $item.Name
    if ($item.PSIsContainer) {
      Copy-QuotabotDirectoryAsHardLinks -Source $item.FullName -Destination $target
    } else {
      New-Item -ItemType HardLink -Path $target -Target $item.FullName | Out-Null
    }
  }
}

function Copy-QuotabotDartSdkMirror {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  $sameVolume = [IO.Path]::GetPathRoot($Source).ToUpperInvariant() -eq
    [IO.Path]::GetPathRoot($Destination).ToUpperInvariant()
  if ($sameVolume) {
    try {
      Copy-QuotabotDirectoryAsHardLinks -Source $Source -Destination $Destination
      return 'hardlink'
    } catch {
      if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
  return 'copy'
}

function Disable-QuotabotSpaceSafeDart {
  param($State)

  if (-not $State) { return }

  if ($null -ne $State.OriginalPath) {
    $env:Path = $State.OriginalPath
  }
  if ($State.PSObject.Properties.Name -contains 'OriginalDartSdk') {
    if ($null -eq $State.OriginalDartSdk) {
      Remove-Item Env:DART_SDK -ErrorAction SilentlyContinue
    } else {
      $env:DART_SDK = $State.OriginalDartSdk
    }
  }
  if ($State.Mirror -and (Test-Path -LiteralPath $State.Mirror)) {
    Remove-Item -LiteralPath $State.Mirror -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Enable-QuotabotSpaceSafeDart {
  param([string]$PreferredRoot)

  $state = [pscustomobject]@{
    OriginalPath = $env:Path
    OriginalDartSdk = $env:DART_SDK
    Mirror = $null
    DartExecutable = $null
    DartSdk = $null
    Kind = 'verbatim'
  }

  try {
    $sdk = Resolve-QuotabotDartSdkPath
    if ($sdk -notmatch ' ') {
      $dart = Join-Path $sdk 'bin\dart.exe'
      $state.DartSdk = $sdk
      $state.DartExecutable = $dart
      $env:DART_SDK = $sdk
      $env:Path = "$(Join-Path $sdk 'bin');$($env:Path)"
      return $state
    }

    $parent = Get-QuotabotSpaceFreeParent -PreferredRoot $PreferredRoot
    $mirror = Join-Path $parent "dart-sdk-$([guid]::NewGuid().ToString('N'))"
    $kind = Copy-QuotabotDartSdkMirror -Source $sdk -Destination $mirror
    $state.Mirror = $mirror
    $state.Kind = $kind
    $dart = Join-Path $mirror 'bin\dart.exe'
    if (-not (Test-Path -LiteralPath $dart -PathType Leaf)) {
      throw "Mapped Dart SDK is missing bin\dart.exe: $dart"
    }
    $state.DartSdk = $mirror
    $state.DartExecutable = $dart
    $env:DART_SDK = $mirror
    $env:Path = "$(Join-Path $mirror 'bin');$($env:Path)"
    return $state
  } catch {
    Disable-QuotabotSpaceSafeDart -State $state
    throw
  }
}
