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

function Resolve-QuotabotFlutterTool {
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $cmd) { return $null }

  $bin = Split-Path -Parent $cmd.Source
  $root = [IO.Path]::GetFullPath((Split-Path -Parent $bin))
  $snapshot = Join-Path $root 'bin\cache\flutter_tools.snapshot'
  $packages = Join-Path $root 'packages\flutter_tools\.dart_tool\package_config.json'
  $dartSdk = Join-Path $root 'bin\cache\dart-sdk'
  if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf) -or
      -not (Test-Path -LiteralPath $packages -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Join-Path $dartSdk 'bin\dart.exe') -PathType Leaf)) {
    throw "Flutter on PATH is incomplete under $root"
  }

  return [pscustomobject]@{
    Root = $root
    Snapshot = $snapshot
    Packages = $packages
    DartSdk = $dartSdk
  }
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

function Copy-QuotabotFileAsLinkOrCopy {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  $sameVolume = [IO.Path]::GetPathRoot($Source).ToUpperInvariant() -eq
    [IO.Path]::GetPathRoot($Destination).ToUpperInvariant()
  if ($sameVolume) {
    try {
      New-Item -ItemType HardLink -Path $Destination -Target $Source | Out-Null
      return
    } catch {}
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function New-QuotabotFlutterSdkView {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  $junctions = [System.Collections.Generic.List[string]]::new()
  try {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $destinationBin = Join-Path $Destination 'bin'
    $destinationCache = Join-Path $destinationBin 'cache'
    New-Item -ItemType Directory -Force -Path $destinationCache | Out-Null

    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
      if ($item.Name -eq 'bin') { continue }
      $target = Join-Path $Destination $item.Name
      if ($item.PSIsContainer) {
        New-Item -ItemType Junction -Path $target -Target $item.FullName | Out-Null
        $junctions.Add($target)
      } else {
        Copy-QuotabotFileAsLinkOrCopy -Source $item.FullName -Destination $target
      }
    }

    $sourceBin = Join-Path $Source 'bin'
    foreach ($item in Get-ChildItem -LiteralPath $sourceBin -Force) {
      if ($item.Name -eq 'cache') { continue }
      $target = Join-Path $destinationBin $item.Name
      if ($item.PSIsContainer) {
        New-Item -ItemType Junction -Path $target -Target $item.FullName | Out-Null
        $junctions.Add($target)
      } else {
        Copy-QuotabotFileAsLinkOrCopy -Source $item.FullName -Destination $target
      }
    }

    $sourceCache = Join-Path $sourceBin 'cache'
    foreach ($item in Get-ChildItem -LiteralPath $sourceCache -Force) {
      if ($item.Name -eq 'dart-sdk') { continue }
      $target = Join-Path $destinationCache $item.Name
      if ($item.PSIsContainer) {
        New-Item -ItemType Junction -Path $target -Target $item.FullName | Out-Null
        $junctions.Add($target)
      } else {
        Copy-QuotabotFileAsLinkOrCopy -Source $item.FullName -Destination $target
      }
    }

    $dartSdk = Join-Path $destinationCache 'dart-sdk'
    $kind = Copy-QuotabotDartSdkMirror `
      -Source (Join-Path $sourceCache 'dart-sdk') `
      -Destination $dartSdk
    return [pscustomobject]@{
      Root = $Destination
      DartSdk = $dartSdk
      Kind = $kind
      Junctions = $junctions.ToArray()
    }
  } catch {
    foreach ($junction in $junctions) {
      Remove-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
    }
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    $destinationParent = [IO.Path]::GetFullPath(
      (Split-Path -Parent $Destination)
    ).TrimEnd('\')
    $leaf = Split-Path -Leaf $destinationPath
    if ($leaf -match '^flutter-sdk-[0-9a-f]{32}$' -and
        $destinationPath.StartsWith(
          "$destinationParent\",
          [StringComparison]::OrdinalIgnoreCase
        )) {
      Remove-Item `
        -LiteralPath $destinationPath `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
    }
    throw
  }
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
  if ($State.PSObject.Properties.Name -contains 'Junctions') {
    foreach ($junction in @($State.Junctions)) {
      if ($junction -and (Test-Path -LiteralPath $junction)) {
        Remove-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
      }
    }
  }
  if ($State.Mirror -and
      $State.MirrorParent -and
      (Test-Path -LiteralPath $State.Mirror)) {
    $mirror = [IO.Path]::GetFullPath($State.Mirror)
    $parent = [IO.Path]::GetFullPath($State.MirrorParent).TrimEnd('\')
    $leaf = Split-Path -Leaf $mirror
    if ($leaf -match '^(dart|flutter)-sdk-[0-9a-f]{32}$' -and
        $mirror.StartsWith("$parent\", [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $mirror -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-QuotabotDart {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  if (-not $State.DartExecutable -or
      -not (Test-Path -LiteralPath $State.DartExecutable -PathType Leaf)) {
    throw 'The space-safe Dart state does not contain a runnable dart.exe.'
  }
  & $State.DartExecutable @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "dart $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Invoke-QuotabotFlutter {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  if (-not $State.FlutterRoot -or
      -not $State.FlutterSnapshot -or
      -not $State.FlutterPackages) {
    throw 'flutter not found on PATH. Install Flutter and add it to PATH.'
  }

  $originalFlutterRoot = $env:FLUTTER_ROOT
  try {
    $env:FLUTTER_ROOT = $State.FlutterRoot
    & $State.DartExecutable `
      "--packages=$($State.FlutterPackages)" `
      $State.FlutterSnapshot `
      @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "flutter $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
  } finally {
    if ($null -eq $originalFlutterRoot) {
      Remove-Item Env:FLUTTER_ROOT -ErrorAction SilentlyContinue
    } else {
      $env:FLUTTER_ROOT = $originalFlutterRoot
    }
  }
}

function Enable-QuotabotSpaceSafeDart {
  param(
    [string]$PreferredRoot,
    [switch]$IncludeFlutter
  )

  $flutter = if ($IncludeFlutter) { Resolve-QuotabotFlutterTool } else { $null }

  $state = [pscustomobject]@{
    OriginalPath = $env:Path
    OriginalDartSdk = $env:DART_SDK
    Mirror = $null
    MirrorParent = $null
    Junctions = @()
    DartExecutable = $null
    DartSdk = $null
    FlutterRoot = $flutter.Root
    FlutterSnapshot = $flutter.Snapshot
    FlutterPackages = $flutter.Packages
    Kind = 'verbatim'
  }

  try {
    $sdk = Resolve-QuotabotDartSdkPath
    if ($flutter -and $flutter.Root -match ' ') {
      $parent = Get-QuotabotSpaceFreeParent -PreferredRoot $PreferredRoot
      $mirror = Join-Path $parent "flutter-sdk-$([guid]::NewGuid().ToString('N'))"
      $view = New-QuotabotFlutterSdkView `
        -Source $flutter.Root `
        -Destination $mirror
      $state.Mirror = $mirror
      $state.MirrorParent = $parent
      $state.Junctions = $view.Junctions
      $state.Kind = $view.Kind
      $state.DartSdk = $view.DartSdk
      $state.DartExecutable = Join-Path $view.DartSdk 'bin\dart.exe'
      $state.FlutterRoot = $view.Root
      $state.FlutterSnapshot = Join-Path $view.Root 'bin\cache\flutter_tools.snapshot'
      $state.FlutterPackages = Join-Path $view.Root 'packages\flutter_tools\.dart_tool\package_config.json'
      $env:DART_SDK = $state.DartSdk
      $env:Path = "$(Join-Path $state.DartSdk 'bin');$($env:Path)"
      return $state
    }
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
    $state.MirrorParent = $parent
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
