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

function Get-WindowsAtlHeader {
  (Get-WindowsDesktopBuildPrereqStatus).AtlHeader
}

function Get-WindowsDesktopBuildPrereqStatus {
  $installPath = Get-VisualStudioInstallPath
  $header = $null
  if ($installPath) {
    $msvcRoot = Join-Path $installPath 'VC\Tools\MSVC'
    if (Test-Path -LiteralPath $msvcRoot) {
      foreach ($toolset in Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue) {
        $candidate = Join-Path $toolset.FullName 'atlmfc\include\atlbase.h'
        if (Test-Path -LiteralPath $candidate) {
          $header = $candidate
          break
        }
      }
    }
  }

  [pscustomobject]@{
    VisualStudioPath = $installPath
    AtlHeader = $header
  }
}

function Assert-WindowsDesktopBuildPrereqs {
  if ($IsWindows -eq $false) { return }
  $status = Get-WindowsDesktopBuildPrereqStatus
  if ($status.AtlHeader) { return $status }

  $selected = if ($status.VisualStudioPath) {
    " Selected Visual Studio instance: $($status.VisualStudioPath)."
  } else {
    ' No Visual Studio instance with MSVC tools was found.'
  }
  throw "Windows desktop builds require the Visual Studio C++ ATL headers (atlbase.h), used by flutter_local_notifications_windows.$selected In Visual Studio Installer, modify that Build Tools instance and add C++ ATL support for its MSVC toolset, then re-run. Use -CliOnly or -NoApp when you only need the CLI."
}
