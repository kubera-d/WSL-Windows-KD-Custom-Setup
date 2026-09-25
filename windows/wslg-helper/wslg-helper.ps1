# WSLg Helper - background fixes for Linux GUI apps under WSLg. Runs hidden at logon (scheduled task
# "WSLg Helper", installed by install.ps1). Windows PowerShell 5.1, must run with -STA (clipboard).
#
# 1. Monitor sync. After sleep / screen-off, WSLg's RDP client (msrdc.exe) reconnects while only one
#    screen is awake, and WSLg keeps that stale layout: Linux windows click in the wrong place and snap
#    to the wrong size. When the layout WSLg last received (weston.log) differs from the real Windows
#    layout for a few seconds, restart msrdc.exe. WSLGd relaunches it within ~1s with the current
#    layout; Linux apps keep running.
#    Also after a LIVE layout change (screens added/removed while connected: weston.log
#    "DisplayLayoutChange", not a fresh connection): the layouts then match, but Linux windows can
#    stop taking clicks and the pointer shape stops updating over parts of them. One msrdc restart
#    once the layout has settled rebuilds the windows.
# 2. Clipboard images. WSLg hands Windows images to Linux only as image/bmp, which Chromium/Electron
#    apps (Linux VS Code and its Claude panel, browsers) cannot paste. When you switch INTO a Linux
#    window with a new Windows image on the clipboard, the image is handed to Linux as image/png.
#    Linux then owns the clipboard and Windows apps would see no image, so when you switch back OUT
#    (having copied nothing new) the original image is put back on the Windows clipboard.
#    Needs wl-clipboard in the distro (install.ps1 installs it).
#
# Manual check:  powershell -STA -File wslg-helper.ps1 -Status
param([switch]$Status, [string]$Distro)

$ErrorActionPreference = 'Continue'
$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$OwnLog = Join-Path $Here 'wslg-helper.log'
$TmpPng = Join-Path $Here 'clipboard.png'

if (-not $Distro) {
    $cfg = Join-Path $Here 'helper-config.json'
    if (Test-Path $cfg) { try { $Distro = (Get-Content $cfg -Raw | ConvertFrom-Json).distro } catch {} }
}
if (-not $Distro) {
    try {
        $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        $def = (Get-ItemProperty $lxss -ErrorAction Stop).DefaultDistribution
        $Distro = (Get-ItemProperty (Join-Path $lxss $def) -ErrorAction Stop).DistributionName
    } catch { $Distro = 'Ubuntu' }
}
$WestonLog = "\\wsl.localhost\$Distro\mnt\wslg\weston.log"

# Monitor-sync tuning
$MonitorEverySec = 5
$StableSec       = 10   # Windows layout must be unchanged this long before acting (monitors settle after wake)
$CooldownSec     = 120  # minimum gap between msrdc restarts
$MaxTries        = 3    # restarts per distinct mismatch before giving up until the layout changes
# Clipboard tuning
$TickMs          = 200
$SettleMs        = 1500 # after handing an image to Linux, wait this long before noting the clipboard sequence

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class WH {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    delegate bool EnumProc(IntPtr h, IntPtr dc, ref RECT r, IntPtr d);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumProc cb, IntPtr d);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static void DpiAware() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {} }
    public static uint Pid(IntPtr h) { uint p = 0; if (h != IntPtr.Zero) GetWindowThreadProcessId(h, out p); return p; }
    public static string Layout() {
        var list = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr dc, ref RECT r, IntPtr d) => {
            list.Add(r.L + "," + r.T + "," + (r.R - r.L) + "," + (r.B - r.T)); return true; }, IntPtr.Zero);
        list.Sort(StringComparer.Ordinal);
        return string.Join(" | ", list);
    }
}
'@
[WH]::DpiAware()

function Write-Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    try {
        if ((Test-Path $OwnLog) -and (Get-Item $OwnLog).Length -gt 512KB) { Move-Item $OwnLog "$OwnLog.old" -Force }
        Add-Content -Path $OwnLog -Value $line -Encoding utf8
    } catch {}
    if ($Status) { Write-Output $line }
}

$script:msrdcCache = @(); $script:msrdcAt = [datetime]::MinValue
function Get-MsrdcPids {
    if (((Get-Date) - $script:msrdcAt).TotalSeconds -ge 2) {
        $script:msrdcCache = @(Get-Process msrdc -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
        $script:msrdcAt = Get-Date
    }
    ,$script:msrdcCache
}

# ---------------------------------------------------------------- monitor sync
# Incremental reader for weston.log: remembers the offset and the latest monitor layout seen.
$script:logPos = 0
$script:wslgLayout = $null
$script:group = @()
$script:liveChange = $false   # a DisplayLayoutChange arrived since the last (re)connect
$monRe = 'rdpMonitor\[(\d+)\]: x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)'

function Update-WslgLayout {
    try { $fs = [IO.File]::Open($WestonLog, 'Open', 'Read', 'ReadWrite, Delete') } catch { return }
    try {
        if ($fs.Length -lt $script:logPos) { $script:logPos = 0; $script:wslgLayout = $null }  # WSL restarted, new log
        if ($fs.Length -eq $script:logPos) { return }
        [void]$fs.Seek($script:logPos, 'Begin')
        $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
        $cut = $text.LastIndexOf("`n")
        if ($cut -lt 0) { return }
        $script:logPos += [Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $cut + 1))
        foreach ($line in $text.Substring(0, $cut).Split("`n")) {
            if ($line.Contains('Client: DisplayLayoutChange')) { $script:liveChange = $true }
            elseif ($line.Contains('xf_peer_adjust_monitor_layout')) { $script:liveChange = $false }   # fresh connection
            if ($line -match $monRe) {
                if ($Matches[1] -eq '0') { $script:group = @() }
                $script:group += '{0},{1},{2},{3}' -f $Matches[2], $Matches[3], $Matches[4], $Matches[5]
                $sorted = [string[]]$script:group; [Array]::Sort($sorted, [StringComparer]::Ordinal)
                $script:wslgLayout = $sorted -join ' | '
            }
        }
    } finally { $fs.Dispose() }
}

$mon = @{ lastWin = $null; winSince = Get-Date; lastRestart = [datetime]::MinValue; triesKey = $null; tries = 0; next = Get-Date }

function Invoke-MonitorSync {
    $win = [WH]::Layout()
    if ($win -ne $mon.lastWin) { $mon.lastWin = $win; $mon.winSince = Get-Date; return }
    if (((Get-Date) - $mon.winSince).TotalSeconds -lt $StableSec) { return }

    Update-WslgLayout
    if ($script:wslgLayout -and $script:wslgLayout -eq $win -and $script:liveChange) {
        if (((Get-Date) - $mon.lastRestart).TotalSeconds -lt $CooldownSec) { return }
        Write-Log "monitors: live layout change to [$win] -> restarting msrdc to rebuild Linux windows"
        Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $mon.lastRestart = Get-Date; $script:liveChange = $false
        return
    }
    if (-not $script:wslgLayout -or $script:wslgLayout -eq $win) { $mon.tries = 0; $mon.triesKey = $null; return }

    $key = "$win => $($script:wslgLayout)"
    if ($key -ne $mon.triesKey) { $mon.triesKey = $key; $mon.tries = 0 }
    if ($mon.tries -ge $MaxTries) { return }
    if (((Get-Date) - $mon.lastRestart).TotalSeconds -lt $CooldownSec) { return }

    Write-Log "monitors: Windows[$win] WSLg[$($script:wslgLayout)] -> restarting msrdc (try $($mon.tries + 1))"
    Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $mon.lastRestart = Get-Date; $mon.tries++
    if ($mon.tries -eq $MaxTries) { Write-Log 'monitors: giving up on this mismatch until the layout changes' }
}

# ---------------------------------------------------------------- clipboard images
# State: seenSeq   = last clipboard sequence number looked at
#        pending   = a Windows-originated image waiting to be handed to Linux (a Bitmap copy)
#        handedSeq = clipboard sequence right after the hand-off settled; if it is unchanged when focus
#                    returns to Windows, nothing new was copied, so the image is restored.
$clip = @{ seenSeq = [WH]::GetClipboardSequenceNumber(); pending = $null; handed = $null; handedSeq = 0; inLinux = $false }

function Get-ClipboardImageSafe {
    for ($i = 0; $i -lt 5; $i++) {
        try { if ([Windows.Forms.Clipboard]::ContainsImage()) { return [Windows.Forms.Clipboard]::GetImage() } else { return $null } }
        catch { Start-Sleep -Milliseconds 50 }
    }
    $null
}

function Set-ClipboardImageSafe($img) {
    for ($i = 0; $i -lt 5; $i++) {
        try { [Windows.Forms.Clipboard]::SetImage($img); return $true } catch { Start-Sleep -Milliseconds 50 }
    }
    $false
}

function Send-ImageToLinux($img) {
    $img.Save($TmpPng, [Drawing.Imaging.ImageFormat]::Png)
    # wl-copy forks and keeps serving the PNG until something else is copied. Its output is detached so
    # wsl.exe returns immediately. Arguments use MSVC quoting (\" inside "...").
    $psi = New-Object Diagnostics.ProcessStartInfo 'wsl.exe'
    $psi.Arguments = "-d $Distro --exec sh -c ""exec wl-copy --type image/png < \""`$(wslpath -u \""`$1\"")\"" >/dev/null 2>&1"" sh ""$TmpPng"""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch {}; return $false }
    $p.ExitCode -eq 0
}

function Invoke-ClipboardTick($msrdc) {
    $seq = [WH]::GetClipboardSequenceNumber()
    if ($seq -ne $clip.seenSeq) {
        $clip.seenSeq = $seq
        # Something new was copied. Only Windows-originated images need help; if msrdc owns the
        # clipboard the content came from Linux and Linux apps already have it natively.
        $owner = [WH]::Pid([WH]::GetClipboardOwner())
        if ($msrdc -notcontains $owner) {
            $img = Get-ClipboardImageSafe
            if ($clip.pending) { $clip.pending.Dispose() }
            $clip.pending = if ($img) { New-Object Drawing.Bitmap $img } else { $null }
            if ($img) { $img.Dispose() }
        }
        if ($seq -ne $clip.handedSeq -and $clip.handed -and $msrdc -notcontains $owner) {
            $clip.handed.Dispose(); $clip.handed = $null    # superseded by a new Windows copy
        }
    }

    $fgLinux = $msrdc -contains [WH]::Pid([WH]::GetForegroundWindow())
    if ($fgLinux -and -not $clip.inLinux) {
        $clip.inLinux = $true
        if ($clip.pending) {
            $img = $clip.pending; $clip.pending = $null
            if (Send-ImageToLinux $img) {
                Start-Sleep -Milliseconds $SettleMs
                $clip.handedSeq = [WH]::GetClipboardSequenceNumber(); $clip.seenSeq = $clip.handedSeq
                if ($clip.handed) { $clip.handed.Dispose() }
                $clip.handed = $img
                Write-Log "clipboard: handed image ($($img.Width)x$($img.Height)) to Linux as PNG"
            } else { $img.Dispose(); Write-Log 'clipboard: wl-copy failed (is wl-clipboard installed in the distro?)' }
        }
    } elseif (-not $fgLinux -and $clip.inLinux) {
        $clip.inLinux = $false
        if ($clip.handed -and [WH]::GetClipboardSequenceNumber() -eq $clip.handedSeq) {
            $img = $clip.handed; $clip.handed = $null
            if (Set-ClipboardImageSafe $img) {
                # Our own SetImage is a new Windows image: it becomes pending again for the next switch in.
                $clip.seenSeq = [WH]::GetClipboardSequenceNumber()
                $clip.pending = $img
                Write-Log 'clipboard: restored image for Windows apps'
            } else { $img.Dispose() }
        }
    }
}

# ---------------------------------------------------------------- main
if ($Status) {
    Update-WslgLayout
    Write-Output ("Distro:  " + $Distro)
    Write-Output ("Windows: " + [WH]::Layout())
    Write-Output ("WSLg:    " + $script:wslgLayout)
    Write-Output ("msrdc:   " + ((Get-MsrdcPids) -join ', '))
    Write-Output ("Apartment: " + [Threading.Thread]::CurrentThread.ApartmentState)
    return
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { Write-Log 'must run with powershell -STA'; exit 1 }
$mutex = New-Object Threading.Mutex($false, 'Local\WslgHelper')
if (-not $mutex.WaitOne(0)) { return }

Write-Log "started (distro $Distro)"
while ($true) {
    Start-Sleep -Milliseconds $TickMs
    try {
        # msrdc only runs while WSLg is up; checking first avoids waking a stopped distro.
        $msrdc = Get-MsrdcPids
        if ($msrdc.Count -eq 0) { $clip.inLinux = $false; continue }
        Invoke-ClipboardTick $msrdc
        if ((Get-Date) -ge $mon.next) { $mon.next = (Get-Date).AddSeconds($MonitorEverySec); Invoke-MonitorSync }
    } catch { Write-Log "error: $($_.Exception.Message)" }
}
