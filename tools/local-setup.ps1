# Local dev setup for quotabot on Windows.
# Uses a dart run shim for the CLI, so no native CLI exe is created.

$ErrorActionPreference = 'Stop'

Write-Host "=== quotabot Local Setup (safe shim) ==="
Write-Host "This setup uses 'dart run' shim for CLI (never builds/runs CLI .exe)."
Write-Host ""

# Resolve the repo root whether this script sits at the root or under tools/.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = if (Test-Path (Join-Path $scriptDir "collector")) { $scriptDir } else { Split-Path -Parent $scriptDir }
$collector = Join-Path $root "collector"
$installDir = "$env:LOCALAPPDATA\quotabot\bin"

# Discover the Flutter/Dart bin directory from PATH, falling back to common
# install locations, so this works on any machine (not just the author's).
function Resolve-FlutterBin {
  foreach ($name in @("flutter", "dart")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return Split-Path -Parent $cmd.Source }
  }
  foreach ($c in @("$env:LOCALAPPDATA\flutter\bin", "C:\flutter\bin", "$env:USERPROFILE\flutter\bin")) {
    if (Test-Path (Join-Path $c "dart.bat")) { return $c }
  }
  throw "Flutter/Dart not found. Install Flutter and ensure 'flutter' is on PATH, then re-run."
}
$flutterBin = Resolve-FlutterBin
Write-Host "Using Flutter/Dart at: $flutterBin"

New-Item -ItemType Directory -Force -Path $installDir | Out-Null

# Safe shim: always uses dart run from the source tree. No .exe involved.
$shim = @"
@echo off
cd /d "$collector"
"$flutterBin\dart.bat" run bin\collect.dart %*
"@
Set-Content "$installDir\quotabot.cmd" -Value $shim -Encoding ASCII
Copy-Item "$installDir\quotabot.cmd" "$installDir\quotabot.bat" -Force

# Add bin dir to PATH (user + current session)
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$userPaths = @($userPath -split ';' | Where-Object { $_ })
if ($userPaths -notcontains $installDir) {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$installDir", "User")
  Write-Host "Added $installDir to your user PATH (permanent for new shells)."
}
$env:Path = "$installDir;$env:Path"

Write-Host ""
Write-Host "Safe 'quotabot' command ready (shim, dart run only)."
Write-Host "Test:"
quotabot doctor 2>&1 | Select-Object -First 8

# Also create robust quotabot-gui launcher (flutter run from SOURCE + deep clean for OneDrive/cmake issues)
# We write a .ps1 with full force-clean logic (handles the common .plugin_symlinks lock + MSB3073)
$guiPs1 = @'
# quotabot-gui.ps1 template output
$ErrorActionPreference = 'Continue'
$binDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = '__ROOT__'
$flutterBin = '__FLUTTERBIN__'
$appDir = Join-Path $root 'app'

$env:Path = "$binDir;$flutterBin;$env:Path"

Write-Host "Starting quotabot GUI from SOURCE (flutter run - gets your login + fixes)"

Get-Process -Name quotabot -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
taskkill /IM quotabot.exe /F /T 2>$null | Out-Null
Start-Sleep -Milliseconds 300

if (!(Test-Path $appDir)) { Write-Error "App dir missing: $appDir"; exit 1 }
Set-Location $appDir

if ($appDir -like "*OneDrive*" -or $PWD -like "*OneDrive*") {
  Write-Host ""
  Write-Warning "Project inside OneDrive - this frequently causes cmake/MSB3073 build failures due to locked files."
  Write-Host "   Long-term fix: move quotabot folder outside OneDrive (example: %USERPROFILE%\dev\quotabot)."
  Write-Host ""
}

Write-Host "Deep cleaning..."
& "$flutterBin\flutter.bat" clean 2>&1 | Out-Null

function Remove-WorkspaceItem {
  param([string]$RelativePath)
  $target = Join-Path $appDir $RelativePath
  if (!(Test-Path -LiteralPath $target)) { return }
  $resolvedRoot = (Resolve-Path -LiteralPath $appDir).Path
  $resolved = (Resolve-Path -LiteralPath $target).Path
  if ($resolved -eq $resolvedRoot -or -not $resolved.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove outside app dir: $resolved"
  }
  $item = Get-Item -LiteralPath $resolved -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove reparse point: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

$paths = @("build", ".dart_tool", "windows\flutter\ephemeral", "windows\CMakeFiles", "windows\x64", "windows\CMakeCache.txt")
foreach ($p in $paths) { Remove-WorkspaceItem $p }

Write-Host "Launching lib\main.dart on Windows in debug mode..."
& "$flutterBin\flutter.bat" run -d windows
'@
$rootLiteral = $root.Replace("'", "''")
$flutterLiteral = $flutterBin.Replace("'", "''")
$guiPs1 = $guiPs1.Replace('__ROOT__', $rootLiteral).Replace('__FLUTTERBIN__', $flutterLiteral)
Set-Content "$installDir\quotabot-gui.ps1" -Value $guiPs1 -Encoding UTF8

$guiCmd = @"
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\quotabot\bin\quotabot-gui.ps1"
endlocal
"@
Set-Content "$installDir\quotabot-gui.cmd" -Value $guiCmd -Encoding ASCII
Copy-Item "$installDir\quotabot-gui.cmd" "$installDir\quotabot-gui.bat" -Force

Write-Host "Also installed 'quotabot-gui' launcher (robust deep-clean version)."

Write-Host ""
Write-Host "Launching desktop app (via flutter)..."
$gui = Join-Path $root "app\build\windows\x64\runner\Release\quotabot.exe"
if (Test-Path $gui) {
  taskkill /IM quotabot.exe /F 2>$null | Out-Null
  Start-Process $gui
  Start-Sleep 1
  # Try to focus it
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
  $p = Get-Process quotabot -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p) {
    [Win32]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
    Start-Sleep -Milliseconds 300
    [Win32]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
    Write-Host "GUI launched & focused (PID $($p.Id))"
  } else {
    Write-Host "App started."
  }
} else {
  Write-Host "GUI not built. Run: cd app; flutter build windows --release"
}

Write-Host ""
Write-Host "Done."
Write-Host "In any terminal: quotabot doctor"
Write-Host "Antigravity persistent login requires QUOTABOT_GOOGLE_CLIENT_ID/SECRET."
Write-Host ""
