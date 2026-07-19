[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$FlutterVersion = '3.44.6',

    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$ExpectedCommit = 'ee80f08bbf97172ec030b8751ceab557177a34a6'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $true
}

if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'RUNNER_TEMP is required.'
}
if ([string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
    throw 'GITHUB_PATH is required.'
}

Get-Command git -ErrorAction Stop | Out-Null

$sourceUrl = 'https://github.com/flutter/flutter.git'
$sdkRoot = Join-Path $env:RUNNER_TEMP "flutter-$FlutterVersion"
if (Test-Path -LiteralPath $sdkRoot) {
    if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot '.git'))) {
        throw "Existing Flutter SDK path is not a Git checkout: $sdkRoot"
    }
} else {
    & git -c core.longpaths=true clone --depth 1 --single-branch --branch $FlutterVersion $sourceUrl $sdkRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to clone Flutter $FlutterVersion."
    }
}

$actualCommit = (& git -C $sdkRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to resolve the Flutter SDK commit.'
}
$actualSource = (& git -C $sdkRoot remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to resolve the Flutter SDK source.'
}
if ($actualSource -ne $sourceUrl) {
    throw "Unexpected Flutter SDK source: $actualSource"
}
if ($actualCommit -ne $ExpectedCommit) {
    throw "Flutter $FlutterVersion resolved to $actualCommit, expected $ExpectedCommit."
}

$flutterBin = Join-Path $sdkRoot 'bin'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::AppendAllText(
    $env:GITHUB_PATH,
    $flutterBin + [Environment]::NewLine,
    $utf8NoBom
)
$env:PATH = $flutterBin + [System.IO.Path]::PathSeparator + $env:PATH

$flutter = if ($IsWindows) {
    Join-Path $flutterBin 'flutter.bat'
} else {
    Join-Path $flutterBin 'flutter'
}
& $flutter config --no-analytics
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to disable Flutter analytics.'
}
& $flutter --version
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to initialize the pinned Flutter SDK.'
}
