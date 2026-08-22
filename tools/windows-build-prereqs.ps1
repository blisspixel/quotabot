$ErrorActionPreference = 'Stop'

function Get-FlutterVisualStudioInstallPath {
  $flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $flutter) { return $null }

  $doctor = & $flutter.Source doctor -v 2>&1
  foreach ($line in $doctor) {
    if ($line -match 'Visual Studio at\s+(.+)$') {
      return $Matches[1].Trim()
    }
  }
  return $null
}

function Get-VisualStudioInstallPath {
  $flutterPath = Get-FlutterVisualStudioInstallPath
  if ($flutterPath) { return $flutterPath }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $path = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
      Select-Object -First 1
    if ($path) { return $path }
  }

  foreach ($root in @(
      "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
      "${env:ProgramFiles}\Microsoft Visual Studio")) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($editionRoot in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
      foreach ($instanceRoot in Get-ChildItem -LiteralPath $editionRoot.FullName -Directory -ErrorAction SilentlyContinue) {
        if (Test-Path -LiteralPath (Join-Path $instanceRoot.FullName 'VC\Tools\MSVC')) {
          return $instanceRoot.FullName
        }
      }
    }
  }

  return $null
}

function Get-WindowsAtlHeaderForInstall {
  param([string]$InstallPath)

  if (-not $InstallPath) { return $null }
  $msvcRoot = Join-Path $InstallPath 'VC\Tools\MSVC'
  if (-not (Test-Path -LiteralPath $msvcRoot)) { return $null }
  foreach ($toolset in Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue) {
    $candidate = Join-Path $toolset.FullName 'atlmfc\include\atlbase.h'
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }
  return $null
}

function Get-WindowsAtlHeader {
  (Get-WindowsDesktopBuildPrereqStatus).AtlHeader
}

function Get-WindowsDesktopBuildPrereqStatus {
  $installPath = Get-VisualStudioInstallPath
  [pscustomobject]@{
    VisualStudioPath = $installPath
    AtlHeader = Get-WindowsAtlHeaderForInstall -InstallPath $installPath
  }
}

function Test-WindowsDesktopAtlAvailable {
  $paths = @()
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $paths += @(& $vswhere -all -products * -property installationPath)
  }
  foreach ($root in @(
      "${env:ProgramFiles(x86)}\Microsoft Visual Studio",
      "${env:ProgramFiles}\Microsoft Visual Studio")) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($editionRoot in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
      foreach ($instanceRoot in Get-ChildItem -LiteralPath $editionRoot.FullName -Directory -ErrorAction SilentlyContinue) {
        $paths += $instanceRoot.FullName
      }
    }
  }

  $seen = @{}
  foreach ($path in $paths) {
    if (-not $path) { continue }
    $normalized = $path.Trim()
    $key = $normalized.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    if (Get-WindowsAtlHeaderForInstall -InstallPath $normalized) {
      return $true
    }
  }
  return $false
}

function Test-WindowsDesktopPluginLinksAvailable {
  $testRoot = Join-Path ([IO.Path]::GetTempPath()) "quotabot-symlink-$([guid]::NewGuid().ToString('N'))"
  $target = Join-Path $testRoot 'target'
  $link = Join-Path $testRoot 'link'
  try {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
    return Test-Path -LiteralPath $link -PathType Container
  } catch {
    return $false
  } finally {
    Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Assert-WindowsDesktopBuildPrereqs {
  if ($IsWindows -eq $false) { return }
  $status = Get-WindowsDesktopBuildPrereqStatus
  if (-not $status.AtlHeader) {
    $selected = if ($status.VisualStudioPath) {
      " Selected Visual Studio instance: $($status.VisualStudioPath)."
    } else {
      ' No Visual Studio instance with MSVC tools was found.'
    }
    throw "Windows desktop builds require the Visual Studio C++ ATL headers (atlbase.h), used by flutter_local_notifications_windows.$selected In Visual Studio Installer, modify that Build Tools instance and add C++ ATL support for its MSVC toolset, then re-run. Use -CliOnly or -NoApp when you only need the CLI."
  }
  if (-not (Test-WindowsDesktopPluginLinksAvailable)) {
    throw 'Windows desktop builds require plugin symlink permission. Enable Windows Developer Mode or run setup from an elevated terminal, then re-run. Use -CliOnly or -NoApp when you only need the CLI.'
  }
  return $status
}
