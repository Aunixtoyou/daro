Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
}
"@ | Out-Null

[Win]::SetProcessDPIAware() | Out-Null
$proc = Get-Process -Name daro -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $proc) { Write-Output "NO-PROCESS"; exit 1 }
$h = $proc.MainWindowHandle
[Win]::ShowWindow($h, 9) | Out-Null    # SW_RESTORE
[Win]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 900
$rect = New-Object Win+Rect
[Win]::GetWindowRect($h, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$hgt = $rect.Bottom - $rect.Top
if ($w -le 0 -or $hgt -le 0) { Write-Output "BAD-RECT $($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom)"; exit 1 }
$bmp = New-Object System.Drawing.Bitmap($w, $hgt)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $hgt)))
$out = "D:\Github\db_lite\app-shot.png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "SAVED $out ${w}x${hgt}"
