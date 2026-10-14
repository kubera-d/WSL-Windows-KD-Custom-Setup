# WSLg Helper - background fixes for Linux GUI apps under WSLg. Runs hidden as the scheduled task
# "WSLg Helper" (installed by install.ps1, no trigger): Dev Control starts it after booting WSL, and it
# exits when WSL stops. Windows PowerShell 5.1, must run with -STA (clipboard).
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
# Never wake WSL: opening anything under \\wsl.localhost or running wsl.exe BOOTS a stopped distro,
# and msrdc.exe outlives a wsl --shutdown by a few seconds. Test-DistroUp gates every Linux access
# (FIX-010 in docs/fixes.md).
#
# Manual check:  powershell -STA -File wslg-helper.ps1 -Status
# Manual rescue: powershell -File wslg-helper.ps1 -Rescue   (moves off-screen Linux windows to the main screen)
param([switch]$Status, [switch]$Rescue, [string]$Distro)

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
# Written by Dev Control while it stops WSL (fresh = stopping, hands off).
$StopMarker = Join-Path $env:LOCALAPPDATA 'DevControl\wsl-stopping'

# Monitor-sync tuning
$MonitorEverySec = 5
$StableSec       = 10   # Windows layout must be unchanged this long before acting (monitors settle after wake)
$CooldownSec     = 120  # minimum gap between msrdc restarts
$WakeIdleSec     = 1200 # a WSLg idle (screen off / lock) at least this long ...
$WakeSettleSec   = 10   # ... is followed, this long after the wake, by one msrdc restart (FIX-017)
$KeepAliveEverySec = 30 # how often to check that the keep-alive wsl.exe session still exists (FIX-017)
$MaxTries        = 3    # restarts per distinct mismatch before giving up until the layout changes
# Clipboard tuning
$TickMs          = 200
$SettleMs        = 1500 # after handing an image to Linux, wait this long before noting the clipboard sequence
$GraceMs         = 3000 # after a hand-off, focus changes are ignored this long (wl-copy's own window steals focus)
$LeaveMs         = 1500 # focus must stay on a Windows app this long before it counts as "left Linux"

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

    // ---- Linux windows (msrdc RAIL_WINDOW top-levels) that are not properly on a current screen
    delegate bool WinProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(WinProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    static List<RECT> WorkAreas() {
        var list = new List<RECT>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr dc, ref RECT r, IntPtr d) => {
            var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(h, ref mi)) list.Add(mi.rcWork); return true; }, IntPtr.Zero);
        return list;
    }
    static long Overlap(RECT a, RECT b) {
        long w = Math.Min(a.R, b.R) - Math.Max(a.L, b.L), h = Math.Min(a.B, b.B) - Math.Max(a.T, b.T);
        return (w > 0 && h > 0) ? w * h : 0;
    }
    // Stranded = its title strip is on no screen, or less than half of it is visible. A window that only
    // grazes the remaining screen (the undocked laptop panel moved from y=1080 to y=0) counts as stranded:
    // WSLg drops such windows when msrdc reconnects.
    static bool Stranded(RECT r, List<RECT> work) {
        var strip = new RECT { L = r.L + 40, T = r.T, R = Math.Max(r.L + 41, r.R - 40), B = r.T + 32 };
        long area = (long)(r.R - r.L) * (r.B - r.T), seen = 0; bool title = false;
        foreach (var w in work) { seen += Overlap(r, w); if (Overlap(strip, w) > 0) title = true; }
        return !title || (area > 0 && seen * 2 < area);
    }
    // Linux top-level windows of the given msrdc processes ("sub-surface" popups move with their parent).
    static List<IntPtr> LinuxWindows(uint[] pids) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (Array.IndexOf(pids, p) < 0 || !IsWindowVisible(h) || IsIconic(h)) return true;
            var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            if (c.ToString() == "RAIL_WINDOW" && t.Length > 0 && !t.ToString().StartsWith("sub-surface")) list.Add(h);
            return true; }, IntPtr.Zero);
        return list;
    }
    // Is there a visible Linux top-level window whose title contains the text?
    public static bool HasWindowTitled(uint[] pids, string part) {
        foreach (var h in LinuxWindows(pids)) {
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            if (t.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) return true;
        }
        return false;
    }
    // Titles of minimized Linux windows. WSLg keeps a minimized window in a layer it does not re-send
    // when msrdc reconnects, and only msrdc can restore it - so a msrdc restart loses it for good.
    public static string MinimizedTitles(uint[] pids) {
        var names = new List<string>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (Array.IndexOf(pids, p) < 0 || !IsIconic(h)) return true;
            var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            if (c.ToString() == "RAIL_WINDOW" && t.Length > 0 && !t.ToString().StartsWith("sub-surface")) names.Add(t.ToString());
            return true; }, IntPtr.Zero);
        return string.Join(" | ", names);
    }
    // Titles of stranded Linux windows, '' when every Linux window is on a screen.
    public static string StrandedTitles(uint[] pids) {
        var work = WorkAreas(); var names = new List<string>();
        foreach (var h in LinuxWindows(pids)) {
            RECT r; if (!GetWindowRect(h, out r) || !Stranded(r, work)) continue;
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256); names.Add(t.ToString());
        }
        return string.Join(" | ", names);
    }
    // Moves stranded Linux windows onto the primary screen's work area (cascaded, shrunk to fit).
    // Only a move: nothing is closed. With rdprail local-move on (FIX-007), WSLg takes over the new
    // position (weston.log "Move order"). Returns how many windows were moved.
    public static int RescueStranded(uint[] pids) {
        var work = WorkAreas();
        var pm = MonitorFromPoint(new POINT(), 1 /* MONITOR_DEFAULTTOPRIMARY */);
        var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(pm, ref mi)) return 0;
        RECT a = mi.rcWork; int n = 0;
        foreach (var h in LinuxWindows(pids)) {
            RECT r; if (!GetWindowRect(h, out r) || !Stranded(r, work)) continue;
            int w = Math.Min(r.R - r.L, a.R - a.L), ht = Math.Min(r.B - r.T, a.B - a.T);
            int x = a.L + 40 * n, y = a.T + 30 * n;
            if (x + w > a.R) x = a.R - w; if (y + ht > a.B) y = a.B - ht;
            // SWP_NOZORDER | SWP_NOACTIVATE
            if (SetWindowPos(h, IntPtr.Zero, x, y, w, ht, 0x0004 | 0x0010)) n++;
        }
        return n;
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
# True only when touching Linux cannot boot it: the WSL VM process exists (checked fresh, it is gone
# right after a shutdown), Dev Control is not stopping WSL, and the distro is listed as running
# (wsl --list --running never boots; cached 15 s).
$script:upAt = [datetime]::MinValue; $script:upOk = $false
function Test-DistroUp {
    if (-not (Get-Process vmmemWSL -ErrorAction SilentlyContinue)) { $script:upAt = [datetime]::MinValue; return $false }
    $m = Get-Item $StopMarker -ErrorAction SilentlyContinue
    if ($m -and ((Get-Date) - $m.LastWriteTime).TotalSeconds -lt 120) { $script:upAt = [datetime]::MinValue; return $false }
    if (((Get-Date) - $script:upAt).TotalSeconds -ge 15) {
        $names = @(& wsl.exe --list --running --quiet 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() })
        $script:upOk = $names -contains $Distro
        $script:upAt = Get-Date
    }
    $script:upOk
}

# Incremental reader for weston.log: remembers the offset and the latest monitor layout seen.
$script:logPos = 0
$script:wslgLayout = $null
$script:group = @()
$script:liveChange = $false   # a DisplayLayoutChange arrived since the last (re)connect
$monRe = 'rdpMonitor\[(\d+)\]: x:(-?\d+), y:(-?\d+), width:(\d+), height:(\d+)'

function Update-WslgLayout {
    if (-not (Test-DistroUp)) { return }
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
            # Idle / wake (screen off or lock, then back): after a long idle the Windows-side windows can
            # come back stale - listed in the taskbar but not opening (FIX-017). Lines read on the first
            # pass are history, not events.
            if ($line -match '^\[(\d\d):(\d\d):(\d\d)[^\]]*\] rdp_rail_(idle|wake)_handler') {
                $sec = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
                if ($Matches[4] -eq 'idle') { $script:idleSec = $sec }
                elseif ($script:logPrimed -and $null -ne $script:idleSec) {
                    $idle = $sec - $script:idleSec; if ($idle -lt 0) { $idle += 86400 }
                    if ($idle -ge $WakeIdleSec) { $script:wokeAt = Get-Date; $script:wokeIdle = $idle }
                }
            }
            # Weston itself restarted (WSLGd relaunches it after a crash - "terminated with signal 11"): every
            # Linux window was cut off and Linux VS Code quit. Forget idle/wake state from before the restart
            # (all windows are new) and let Invoke-CodeRecovery reopen VS Code (FIX-020).
            if ($line -match '\] Command line: /usr/bin/weston ') {
                $script:idleSec = $null; $script:wokeAt = $null
                if ($script:logPrimed) { $script:westonRestartAt = Get-Date }
            }
            if ($line.Contains('Client: DisplayLayoutChange')) { $script:liveChange = $true }
            elseif ($line.Contains('xf_peer_adjust_monitor_layout')) { $script:liveChange = $false }   # fresh connection
            if ($line -match $monRe) {
                if ($Matches[1] -eq '0') { $script:group = @() }
                $script:group += '{0},{1},{2},{3}' -f $Matches[2], $Matches[3], $Matches[4], $Matches[5]
                $sorted = [string[]]$script:group; [Array]::Sort($sorted, [StringComparer]::Ordinal)
                $script:wslgLayout = $sorted -join ' | '
            }
        }
        $script:logPrimed = $true
    } finally { $fs.Dispose() }
}

# Keep-alive watchdog (FIX-017). Dev Control starts a hidden `wsl.exe ... exec sleep infinity` session at
# boot so WSL does not idle itself out while only GUI apps (Linux VS Code) run - those do not count as
# WSL clients. If that session dies, WSL can stop under open windows. While the distro is up (never
# boots it), recreate it. Off when Dev Control's settings.json says "keepAlive": false.
$KeepAliveOn = $true
try {
    $dc = Join-Path $env:LOCALAPPDATA 'Programs\DevControl\settings.json'
    if (Test-Path $dc) { $j = Get-Content -Raw $dc | ConvertFrom-Json; if ($j.PSObject.Properties['keepAlive'] -and -not $j.keepAlive) { $KeepAliveOn = $false } }
} catch {}
$script:keepAliveProc = $null; $script:keepAliveNext = Get-Date

function Invoke-KeepAliveCheck {
    if (-not $KeepAliveOn -or (Get-Date) -lt $script:keepAliveNext) { return }
    $script:keepAliveNext = (Get-Date).AddSeconds($KeepAliveEverySec)
    if (-not (Test-DistroUp)) { return }
    $ka = @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*exec sleep infinity*' })
    if ($ka.Count) { return }
    $psi = New-Object Diagnostics.ProcessStartInfo 'wsl.exe', "-d $Distro -- bash -lc `"exec sleep infinity`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $script:keepAliveProc = [Diagnostics.Process]::Start($psi)   # keep the object: its stdin pipe must stay open
    Write-Log 'keep-alive: the session was gone (WSL could idle out under open windows) - started a new one'
}

# FIX-020: when WSLg's display server (Weston) crashes, Linux VS Code loses its display and quits with every
# window. If VS Code windows were on screen shortly before, reopen VS Code: code-linux with no folder makes
# it restore all windows of the last session (window.restoreWindows), Claude panels included. Only if no
# VS Code process is running any more, and at most once per restart.
$script:codeSeenAt = [datetime]::MinValue; $script:westonRestartAt = $null

function Update-CodeSeen {
    $pids = [uint32[]](Get-MsrdcPids)
    if ($pids.Count -and [WH]::HasWindowTitled($pids, 'Visual Studio Code')) { $script:codeSeenAt = Get-Date }
}

function Invoke-CodeRecovery {
    if (-not $script:westonRestartAt) { return }
    if (((Get-Date) - $script:westonRestartAt).TotalSeconds -lt 15) { return }   # let WSLg and msrdc settle
    $restartAt = $script:westonRestartAt; $script:westonRestartAt = $null
    if (($restartAt - $script:codeSeenAt).TotalSeconds -gt 180) { return }      # VS Code was not open
    if (-not (Test-DistroUp)) { return }
    $sh = "[ -x `"`$HOME/.local/bin/code-linux`" ] || exit 127`n" +
          "pgrep -f /usr/share/code/code >/dev/null && exit 3`n" +
          "cd `"`$HOME`" && setsid -f `"`$HOME/.local/bin/code-linux`" >/dev/null 2>&1`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
    $psi = New-Object Diagnostics.ProcessStartInfo 'wsl.exe', "-d $Distro -- bash -lc `"echo $b64 | base64 -d | bash`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(30000)) { Write-Log 'WSLg display server restarted - reopening VS Code timed out'; return }
    switch ($p.ExitCode) {
        0       { Write-Log 'WSLg display server crashed and restarted - reopened Linux VS Code (it restores its windows)' }
        3       { Write-Log 'WSLg display server restarted - Linux VS Code is still running, nothing to reopen' }
        127     { Write-Log 'WSLg display server restarted - ~/.local/bin/code-linux missing, cannot reopen VS Code' }
        default { Write-Log "WSLg display server restarted - reopening VS Code failed (exit $($p.ExitCode))" }
    }
}

$mon = @{ lastWin = $null; winSince = Get-Date; lastRestart = [datetime]::MinValue; triesKey = $null; tries = 0; next = Get-Date; rescues = 0; rescuedFor = $null; minLogged = $null }

# A msrdc restart makes WSLg re-send its windows, and it drops every Linux window that is not on a
# current screen: after undocking they vanish (no window, nothing in the taskbar) until the screens
# come back (FIX-012). So before any restart, Linux windows left on a removed screen are moved onto the
# primary screen; the restart waits a pass so WSLg receives the moves. If a window will not move, the
# restart is skipped - stale clicks (FIX-009) are better than lost windows.
function Test-SafeToRestartMsrdc {
    $pids = [uint32[]](Get-MsrdcPids)
    if ($pids.Count -eq 0) { return $true }
    # Windows minimizes windows of a disconnected monitor; a minimized Linux window does not survive a
    # msrdc restart (FIX-012). Wait until none is minimized.
    $min = [WH]::MinimizedTitles($pids)
    if ($min) {
        if ($mon.minLogged -ne $min) { Write-Log "monitors: NOT restarting msrdc while Linux window(s) are minimized (they would be lost): $min"; $mon.minLogged = $min }
        return $false
    }
    $mon.minLogged = $null
    $left = [WH]::StrandedTitles($pids)
    if (-not $left) { $mon.rescues = 0; return $true }
    if ($mon.rescues -ge 2) {
        Write-Log "monitors: NOT restarting msrdc - Linux window(s) still off-screen and would be lost: $left"
        return $false
    }
    $n = [WH]::RescueStranded($pids)
    $mon.rescues++
    Write-Log "monitors: moved $n Linux window(s) onto the main screen before restarting msrdc: $left"
    $mon.next = (Get-Date).AddSeconds(3)   # let WSLg take the new positions, then check again
    $false
}

function Invoke-MonitorSync {
    $win = [WH]::Layout()
    if ($win -ne $mon.lastWin) { $mon.lastWin = $win; $mon.winSince = Get-Date; return }
    if (((Get-Date) - $mon.winSince).TotalSeconds -lt $StableSec) { return }

    # Screens changed (undocked): bring Linux windows left on a removed screen to the main screen, like
    # Windows does for its own windows. Only in the first minute after a change, so a window you park
    # half off-screen yourself is left alone.
    if ($mon.lastWin -ne $mon.rescuedFor -and ((Get-Date) - $mon.winSince).TotalSeconds -lt 70) {
        $pids = [uint32[]](Get-MsrdcPids)
        $left = if ($pids.Count) { [WH]::StrandedTitles($pids) } else { '' }
        if ($left) {
            $n = [WH]::RescueStranded($pids)
            Write-Log "monitors: screens changed - moved $n Linux window(s) onto the main screen: $left"
            $mon.next = (Get-Date).AddSeconds(3)
            return
        }
        $mon.rescuedFor = $mon.lastWin
    }

    Update-WslgLayout
    # A freshly booted WSLg logs a 0x0 placeholder monitor before msrdc connects: not a real layout.
    if ($script:wslgLayout -match '(^| )-?\d+,-?\d+,0,0($| )') { return }
    # Woke from a long idle: rebuild the windows once things have settled, so they open again (FIX-017).
    if ($script:wokeAt -and ((Get-Date) - $script:wokeAt).TotalSeconds -ge $WakeSettleSec) {
        if (((Get-Date) - $mon.lastRestart).TotalSeconds -lt $CooldownSec) { $script:wokeAt = $null; return }
        if (-not (Test-SafeToRestartMsrdc)) { return }
        Write-Log ("monitors: woke after {0} min idle -> restarting msrdc so Linux windows open again" -f [int]($script:wokeIdle / 60))
        Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $mon.lastRestart = Get-Date; $script:wokeAt = $null; $script:liveChange = $false
        return
    }
    if ($script:wslgLayout -and $script:wslgLayout -eq $win -and $script:liveChange) {
        if (((Get-Date) - $mon.lastRestart).TotalSeconds -lt $CooldownSec) { return }
        if (-not (Test-SafeToRestartMsrdc)) { return }
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
    if (-not (Test-SafeToRestartMsrdc)) { return }

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
$clip = @{ seenSeq = [WH]::GetClipboardSequenceNumber(); pending = $null; handed = $null; handedSeq = 0; inLinux = $false
          graceUntil = [datetime]::MinValue; outSince = $null }

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

# Copy in Linux, paste in Outlook (or any Windows app that asks for HTML first) pasted nothing: WSLg
# advertises "HTML Format", but its Linux-to-Windows HTML conversion needs an <html> tag, and Chromium /
# VS Code copy HTML fragments without one, so the request fails and the app gives up (weston.log
# "clipboard_process_html FAILED ... send"). When a Linux copy carries HTML that cannot be fetched, put
# its plain text back on the Windows clipboard ourselves (FIX-018).
function Repair-LinuxHtmlCopy {
    try {
        if (-not [Windows.Forms.Clipboard]::ContainsData('HTML Format')) { return }
        $html = $null
        try { $html = [Windows.Forms.Clipboard]::GetData('HTML Format') } catch {}
        if ($html -and "$html".Length -gt 0) { return }            # WSLg delivered it: nothing to repair
        $text = [Windows.Forms.Clipboard]::GetText()
        if (-not $text) { return }
        for ($i = 0; $i -lt 5; $i++) {
            try { [Windows.Forms.Clipboard]::SetDataObject($text, $true); break } catch { Start-Sleep -Milliseconds 50 }
        }
        $clip.seenSeq = [WH]::GetClipboardSequenceNumber()
        Write-Log "clipboard: Linux copy had HTML that WSLg cannot convert - put its plain text ($($text.Length) chars) on the Windows clipboard"
    } catch {}
}

function Invoke-ClipboardTick($msrdc) {
    $seq = [WH]::GetClipboardSequenceNumber()
    if ($seq -ne $clip.seenSeq) {
        $clip.seenSeq = $seq
        if ($msrdc -contains [WH]::Pid([WH]::GetClipboardOwner())) { Repair-LinuxHtmlCopy }
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

    $fgPid = [WH]::Pid([WH]::GetForegroundWindow())
    $fgLinux = $msrdc -contains $fgPid
    # wl-copy briefly opens its own window to take the clipboard; under WSLg that steals focus and
    # Windows often hands it back to the previous Windows app. Restoring then would replace the PNG on
    # the Linux clipboard with a BMP that Linux VS Code cannot paste (FIX-015). So "left Linux" only
    # counts after the grace period and once focus has stayed on a Windows app for $LeaveMs.
    if ($fgLinux) { $clip.outSince = $null }
    elseif ($clip.inLinux) {
        if (-not $clip.outSince) { $clip.outSince = Get-Date }
        if ((Get-Date) -lt $clip.graceUntil -or ((Get-Date) - $clip.outSince).TotalMilliseconds -lt $LeaveMs) { return }
    }
    if ($fgLinux -and -not $clip.inLinux) {
        $clip.inLinux = $true
        if ($clip.pending -and (Test-DistroUp)) {
            $img = $clip.pending; $clip.pending = $null
            if (Send-ImageToLinux $img) {
                Start-Sleep -Milliseconds $SettleMs
                $clip.handedSeq = [WH]::GetClipboardSequenceNumber(); $clip.seenSeq = $clip.handedSeq
                if ($clip.handed) { $clip.handed.Dispose() }
                $clip.handed = $img
                $clip.graceUntil = (Get-Date).AddMilliseconds($GraceMs)
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
                $to = try { (Get-Process -Id $fgPid -ErrorAction Stop).Name } catch { "pid $fgPid" }
                Write-Log "clipboard: restored image for Windows apps (focus moved to $to)"
            } else { $img.Dispose() }
        }
    }
}

# ---------------------------------------------------------------- main
if ($Status) {
    Update-WslgLayout
    Write-Output ("Distro:  " + $Distro)
    Write-Output ("Up:      " + (Test-DistroUp))
    Write-Output ("Windows: " + [WH]::Layout())
    Write-Output ("WSLg:    " + $script:wslgLayout)
    Write-Output ("msrdc:   " + ((Get-MsrdcPids) -join ', '))
    Write-Output ("Off-screen Linux windows: " + [WH]::StrandedTitles([uint32[]](Get-MsrdcPids)))
    Write-Output ("Minimized Linux windows:  " + [WH]::MinimizedTitles([uint32[]](Get-MsrdcPids)))
    Write-Output ("Keep-alive sessions:      " + @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -like '*exec sleep infinity*' }).Count)
    Write-Output ("Apartment: " + [Threading.Thread]::CurrentThread.ApartmentState)
    return
}
if ($Rescue) {
    $pids = [uint32[]](Get-MsrdcPids)
    $left = [WH]::StrandedTitles($pids)
    if (-not $left) { Write-Output 'No off-screen Linux windows (a window WSLg already dropped cannot be moved - reconnect the screen it was on).'; return }
    $n = [WH]::RescueStranded($pids)
    Write-Log "rescue: moved $n Linux window(s) onto the main screen: $left"
    Write-Output "Moved $n window(s): $left"
    return
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { Write-Log 'must run with powershell -STA'; exit 1 }
$mutex = New-Object Threading.Mutex($false, 'Local\WslgHelper')
if (-not $mutex.WaitOne(0)) { return }

# Lives only as long as WSL: Dev Control starts the task after it boots WSL, and the helper exits when
# WSL stops (any way: Dev Control, wsl --shutdown, idle timeout). Nothing runs while WSL is down.
# The task also runs every 2 minutes (FIX-019) so the helper is up whenever WSL is, however WSL was started.
# While WSL is down that is a quiet no-op: log the exit once, not every run.
if (-not (Test-DistroUp)) {
    $msg = 'WSL is not running - exiting (the task tries again every 2 minutes)'
    $last = Get-Content $OwnLog -Tail 1 -ErrorAction SilentlyContinue
    if ("$last" -notlike "*$msg") { Write-Log $msg }
    exit 0
}
Write-Log "started (distro $Distro)"
$downCheck = Get-Date
while ($true) {
    Start-Sleep -Milliseconds $TickMs
    try {
        if ((Get-Date) -ge $downCheck) {
            $downCheck = (Get-Date).AddSeconds(2)
            $m = Get-Item $StopMarker -ErrorAction SilentlyContinue
            $stopping = $m -and ((Get-Date) - $m.LastWriteTime).TotalSeconds -lt 120
            if ($stopping -or -not (Get-Process vmmemWSL -ErrorAction SilentlyContinue)) {
                Write-Log $(if ($stopping) { 'Dev Control is stopping WSL - exiting' } else { 'WSL stopped - exiting' })
                exit 0
            }
        }
        # msrdc only runs while WSLg is up; checking first avoids waking a stopped distro.
        $msrdc = Get-MsrdcPids
        if ($msrdc.Count -eq 0) { $clip.inLinux = $false; continue }
        Invoke-ClipboardTick $msrdc
        if ((Get-Date) -ge $mon.next) { $mon.next = (Get-Date).AddSeconds($MonitorEverySec); Update-CodeSeen; Invoke-MonitorSync; Invoke-CodeRecovery }
        Invoke-KeepAliveCheck
    } catch { Write-Log "error: $($_.Exception.Message)" }
}
