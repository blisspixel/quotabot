# Dev helper: launch the built app, bring it to front, and screenshot its window.
param([string]$Out = "$PSScriptRoot\shot.png", [int]$Wait = 7)
$exe = Join-Path $PSScriptRoot '..\app\build\windows\x64\runner\Debug\quotabot.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
  throw "Debug build not found at $exe. Run: cd app; flutter build windows --debug"
}

$resolvedExe = (Resolve-Path -LiteralPath $exe).Path
Get-Process quotabot -ErrorAction SilentlyContinue |
  Where-Object {
    try { $_.Path -eq $resolvedExe } catch { $false }
  } |
  Stop-Process -Force
Start-Sleep -Milliseconds 400

$p = Start-Process -FilePath $resolvedExe -PassThru
Start-Sleep -Seconds $Wait
Add-Type @"
using System;using System.Runtime.InteropServices;
public class Cap{
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int cx,int cy,uint f);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
 [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
 public struct RECT{public int Left,Top,Right,Bottom;} }
"@
$p.Refresh()
if ($p.HasExited) {
  throw "quotabot exited before capture could start."
}

for ($i = 0; $i -lt 20; $i++) {
  $p.Refresh()
  if ($p.MainWindowHandle -ne [IntPtr]::Zero) { break }
  Start-Sleep -Milliseconds 250
}

$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) {
  throw "quotabot did not create a main window before capture timed out."
}

$HWND_TOPMOST = New-Object IntPtr(-1)
[Cap]::ShowWindow($h,9) | Out-Null          # SW_RESTORE
[Cap]::SetWindowPos($h,$HWND_TOPMOST,80,80,0,0,0x0001) | Out-Null  # TOPMOST, keep size
[Cap]::BringWindowToTop($h) | Out-Null
[Cap]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 700
Add-Type -AssemblyName System.Drawing
$r = New-Object Cap+RECT
if (-not [Cap]::GetWindowRect($h,[ref]$r)) {
  throw "Could not read the quotabot window rectangle."
}

$w=$r.Right-$r.Left; $ht=$r.Bottom-$r.Top
if ($w -le 0 -or $ht -le 0) {
  throw "Invalid quotabot window size: ${w}x${ht}."
}

$bmp=New-Object System.Drawing.Bitmap($w,$ht); $g=[System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left,$r.Top,0,0,$bmp.Size)
$bmp.Save($Out)
$g.Dispose()
$bmp.Dispose()
"saved $Out (${w}x${ht}) at $($r.Left),$($r.Top)"
