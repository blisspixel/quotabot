$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-space-safe-dart.ps1')
. (Join-Path $PSScriptRoot 'windows-build-prereqs.ps1')

$atl = Test-WindowsDesktopAtlAvailable
if ($atl -ne $true -and $atl -ne $false) {
  throw 'Test-WindowsDesktopAtlAvailable did not return a boolean.'
}
$pluginLinks = Test-WindowsDesktopPluginLinksAvailable
if ($pluginLinks -ne $true -and $pluginLinks -ne $false) {
  throw 'Test-WindowsDesktopPluginLinksAvailable did not return a boolean.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$parent = Get-QuotabotSpaceFreeParent -PreferredRoot $repoRoot
if ($parent -match ' ') {
  throw "Space-free parent still contains spaces: $parent"
}
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
  throw "Space-free parent was not created: $parent"
}

$fixtureRoot = Join-Path $parent "space-safe-fixture-$([guid]::NewGuid().ToString('N'))"
$source = Join-Path $fixtureRoot 'sdk with spaces'
$destination = Join-Path $fixtureRoot 'mirror'
New-Item -ItemType Directory -Force -Path (Join-Path $source 'bin') | Out-Null
Set-Content -LiteralPath (Join-Path $source 'bin\dart.exe') -Value 'sdk' -NoNewline
try {
  $kind = Copy-QuotabotDartSdkMirror -Source $source -Destination $destination
  if ($kind -ne 'hardlink' -and $kind -ne 'copy') {
    throw "Unexpected mirror kind: $kind"
  }
  $mirrored = Join-Path $destination 'bin\dart.exe'
  if (-not (Test-Path -LiteralPath $mirrored -PathType Leaf)) {
    throw "Mirrored dart.exe is missing: $mirrored"
  }
  if ($mirrored -match ' ') {
    throw "Mirrored dart.exe still contains spaces: $mirrored"
  }
  $content = Get-Content -LiteralPath $mirrored -Raw
  if ($content -ne 'sdk') {
    throw 'Mirrored dart.exe content did not match.'
  }
  $copyDestination = Join-Path $fixtureRoot 'copied'
  Copy-Item -LiteralPath $source -Destination $copyDestination -Recurse -Force
  $copied = Join-Path $copyDestination 'bin\dart.exe'
  if (-not (Test-Path -LiteralPath $copied -PathType Leaf)) {
    throw "Copy fallback layout is missing bin\dart.exe: $copied"
  }
} finally {
  Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$spaceSafe = $null
$originalPath = $env:Path
$originalDartSdk = $env:DART_SDK
$originalFlutter = Resolve-QuotabotFlutterTool
try {
  $spaceSafe = Enable-QuotabotSpaceSafeDart `
    -PreferredRoot $repoRoot `
    -IncludeFlutter
  if (-not (Test-Path -LiteralPath $spaceSafe.DartExecutable -PathType Leaf)) {
    throw "Enable-QuotabotSpaceSafeDart did not resolve dart.exe: $($spaceSafe.DartExecutable)"
  }
  if ($spaceSafe.DartExecutable -match ' ') {
    throw "Mapped dart.exe still contains spaces: $($spaceSafe.DartExecutable)"
  }
  if ($spaceSafe.Kind -notin @('verbatim', 'hardlink', 'copy')) {
    throw "Unexpected Dart mapping kind: $($spaceSafe.Kind)"
  }
  $sdkPath = Resolve-QuotabotDartSdkPath
  if ($sdkPath -match ' ' -and $spaceSafe.Kind -eq 'verbatim') {
    throw 'A spaced Dart SDK must be mirrored, not used verbatim.'
  }
  if ($spaceSafe.Kind -ne 'verbatim' -and -not $spaceSafe.Mirror) {
    throw 'A mirrored Dart SDK did not record its temporary directory.'
  }
  if ($originalFlutter -and $originalFlutter.Root -match ' ') {
    if ($spaceSafe.FlutterRoot -match ' ') {
      throw "Mapped Flutter root still contains spaces: $($spaceSafe.FlutterRoot)"
    }
    $flutterDart = Join-Path $spaceSafe.FlutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
    if (-not (Test-Path -LiteralPath $flutterDart -PathType Leaf)) {
      throw "Mapped Flutter root is missing its Dart executable: $flutterDart"
    }
  }
  $version = & $spaceSafe.DartExecutable --version 2>&1 | Select-Object -First 1
  if ("$version" -notmatch 'Dart SDK version') {
    throw "Mapped dart.exe did not report a Dart SDK version: $version"
  }
  if ($spaceSafe.FlutterSnapshot) {
    $flutterVersion = @(
      Invoke-QuotabotFlutter -State $spaceSafe -Arguments @('--version') 2>&1
    ) -join "`n"
    if ($flutterVersion -notmatch 'Flutter') {
      throw "Space-safe Flutter invocation did not report a version: $flutterVersion"
    }
  }
} finally {
  $mirror = $null
  if ($spaceSafe) { $mirror = $spaceSafe.Mirror }
  Disable-QuotabotSpaceSafeDart -State $spaceSafe
  if ($mirror -and (Test-Path -LiteralPath $mirror)) {
    throw "Disable-QuotabotSpaceSafeDart left the Dart SDK mirror: $mirror"
  }
}

if ($env:Path -ne $originalPath) {
  throw 'Disable-QuotabotSpaceSafeDart did not restore PATH.'
}
if ($null -eq $originalDartSdk) {
  if (Test-Path Env:DART_SDK) {
    throw 'Disable-QuotabotSpaceSafeDart did not clear DART_SDK.'
  }
} elseif ($env:DART_SDK -ne $originalDartSdk) {
  throw 'Disable-QuotabotSpaceSafeDart did not restore DART_SDK.'
}

Write-Host 'Windows space-safe Dart helper tests passed.'
