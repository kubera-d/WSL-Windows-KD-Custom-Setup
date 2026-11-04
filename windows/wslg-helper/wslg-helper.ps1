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
# 3. Leaked WSL relays. Some wsl.exe calls leave their Linux-side "Relay" process behind; once dozens pile
#    up, every new wsl.exe call (and Linux running explorer.exe / clip.exe) slows down and then hangs.
#    Every few minutes the leaked ones are ended (FIX-030).
#
# Never wake WSL: opening anything under \\wsl.localhost or running wsl.exe BOOTS a stopped distro,
# and msrdc.exe outlives a wsl --shutdown by a few seconds. Test-DistroUp gates every Linux access
# (FIX-010 in docs/fixes.md).
#
# Manual check:  powershell -STA -File wslg-helper.ps1 -Status
# Manual rescue: powershell -File wslg-helper.ps1 -Rescue   (moves off-screen Linux windows to the main screen)
# Full repair:   powershell -File wslg-helper.ps1 -Repair   (Dev Control's Fix Linux windows button)
# Relay cleanup: powershell -File wslg-helper.ps1 -Reap     (Dev Control's Fix WSL button, FIX-030)
param([switch]$Status, [switch]$Rescue, [switch]$Repair, [switch]$Reap, [string]$Distro)

$ErrorActionPreference = 'Continue'
$Here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$OwnLog = Join-Path $Here 'wslg-helper.log'
$TmpPng = Join-Path $Here 'clipboard.png'

# helper-config.json: distro (written by install.ps1); "wakeRestart": true turns the FIX-017 restart after a
# wake back on (off since FIX-024).
$WakeRestart = $false
$cfg = Join-Path $Here 'helper-config.json'
if (Test-Path $cfg) {
    try {
        $hc = Get-Content $cfg -Raw | ConvertFrom-Json
        if (-not $Distro) { $Distro = $hc.distro }
        if ($hc.PSObject.Properties['wakeRestart']) { $WakeRestart = [bool]$hc.wakeRestart }
    } catch {}
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
$WakeSettleSec   = 10   # ... is followed, this long after the wake, by one msrdc restart (FIX-017; only with wakeRestart)
$KeepAliveEverySec = 5  # how often to check that the keep-alive wsl.exe session still exists (FIX-017; 5 s: WSL idle-stops a distro within seconds of its last session, FIX-026)
$MaxTries        = 3    # restarts per distinct mismatch before giving up until the layout changes
$YoungMsrdcSec   = 45   # never restart a msrdc that started less than this long ago (still connecting, FIX-025)
$RelayReapEverySec = 300 # how often to end leaked wsl.exe relay processes in the distro (FIX-030)
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
    // Restores minimized Linux windows (what a taskbar click does) so a msrdc restart cannot lose them.
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
    public static int RestoreMinimized(uint[] pids) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (Array.IndexOf(pids, p) < 0 || !IsIconic(h)) return true;
            var c = new System.Text.StringBuilder(64); GetClassName(h, c, 64);
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            if (c.ToString() == "RAIL_WINDOW" && t.Length > 0 && !t.ToString().StartsWith("sub-surface")) list.Add(h);
            return true; }, IntPtr.Zero);
        int n = 0;
        foreach (var h in list) if (ShowWindowAsync(h, 9 /* SW_RESTORE */)) n++;
        return n;
    }
    // How many visible Linux top-level windows have the text in their title.
    public static int CountTitled(uint[] pids, string part) {
        int n = 0;
        foreach (var h in LinuxWindows(pids)) {
            var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
            if (t.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) n++;
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

# Timers use a monotonic clock, not the wall clock: a clock correction (a 4 h jump after booting Linux,
# which keeps the hardware clock in UTC) froze every cooldown and schedule until the clock caught up, so
# the monitor sync skipped a dock (FIX-021). Only the log and file-time comparisons use Get-Date.
$script:clockBase = Get-Date; $script:clock = [Diagnostics.Stopwatch]::StartNew()
function Get-Now { $script:clockBase.Add($script:clock.Elapsed) }

$script:msrdcCache = @(); $script:msrdcAt = [datetime]::MinValue
function Get-MsrdcPids {
    if (((Get-Now) - $script:msrdcAt).TotalSeconds -ge 2) {
        $script:msrdcCache = @(Get-Process msrdc -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
        $script:msrdcAt = Get-Now
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
    if (((Get-Now) - $script:upAt).TotalSeconds -ge 15) {
        $names = @(& wsl.exe --list --running --quiet 2>$null | ForEach-Object { ($_ -replace "`0", '').Trim() })
        $script:upOk = $names -contains $Distro
        $script:upAt = Get-Now
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
                if ($Matches[4] -eq 'idle') { $script:idleSec = $sec; $script:awaySeen = $false }
                elseif ($script:logPrimed -and $null -ne $script:idleSec) {
                    $idle = $sec - $script:idleSec; if ($idle -lt 0) { $idle += 86400 }
                    # WSLg is "idle" whenever no Linux window gets input - also while you work in Windows
                    # apps (a Teams call). Only a real absence (locked or asleep) leaves stale windows; a
                    # restart after mere Windows work hit the start of a dictation and crashed WSLg (FIX-023).
                    # Off by default: on this hardware msrdc keeps its connection through Modern Standby, so the
                    # restart was the only reconnect and made every Linux window vanish ~10 s after each wake.
                    # Stale windows after a wake: Dev Control's Fix windows (FIX-024).
                    if ($idle -ge $WakeIdleSec -and $script:awaySeen -and -not $WakeRestart) { Write-Log ("monitors: woke after {0} min away - windows left as they are (wakeRestart off; Fix windows in Dev Control if they do not open)" -f [int]($idle / 60)) }
                    elseif ($idle -ge $WakeIdleSec -and $script:awaySeen) { $script:wokeAt = Get-Now; $script:wokeIdle = $idle }
                    elseif ($idle -ge $WakeIdleSec) { Write-Log ("monitors: Linux windows idle {0} min while Windows was in use (not locked/asleep) - no restart" -f [int]($idle / 60)) }
                    $script:awaySeen = $false
                }
            }
            # Weston itself restarted (WSLGd relaunches it after a crash - "terminated with signal 11"): every
            # Linux window was cut off and Linux VS Code quit. Forget idle/wake state from before the restart
            # (all windows are new) and let Invoke-CodeRecovery reopen VS Code (FIX-020).
            if ($line -match '\] Command line: /usr/bin/weston ') {
                $script:idleSec = $null; $script:wokeAt = $null
                if ($script:logPrimed) { $script:westonRestartAt = Get-Now }
            }
            # Only a change seen live counts: one in the history read at helper start would restart msrdc
            # (blink every Linux window) for a change that was dealt with long ago.
            if ($line.Contains('Client: DisplayLayoutChange')) { if ($script:logPrimed) { $script:liveChange = $true } }
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
$script:keepAliveProc = $null; $script:keepAliveNext = Get-Now

function Invoke-KeepAliveCheck {
    if (-not $KeepAliveOn -or (Get-Now) -lt $script:keepAliveNext) { return }
    $script:keepAliveNext = (Get-Now).AddSeconds($KeepAliveEverySec)
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

# FIX-030: WSL 2.7 sometimes leaves the Linux end of a finished wsl.exe call running - a root process named
# exactly "Relay", orphaned (parent PID 1), with no children, waiting forever. Dev Control's 30 s polls left
# ~70 in a day; with that many, new wsl.exe calls took 30 s and then failed (Wsl/Service/0x8007274c), and so
# did Linux-to-Windows calls (explorer.exe, clip.exe) and the screenshot hand-off (wl-copy). Live relays are
# named "Relay(<pid>)" or have a child, so they never match. They ignore SIGTERM, hence SIGKILL; the count
# logged is how many are actually gone. Runs as root without waiting for the result:
# while WSL is slow, a blocking call would stall the clipboard handling.
$script:reapProc = $null; $script:reapStarted = $null; $script:reapNext = (Get-Now).AddSeconds(60)
$ReapSh = @'
parents=" $(echo $(ps -eo ppid=)) "
gone=""
for p in $(ps -eo pid=,ppid=,etimes=,comm= | awk '$4=="Relay" && $2==1 && $3>MINAGE {print $1}'); do
  case "$parents" in *" $p "*) continue ;; esac
  kill -KILL "$p" 2>/dev/null && gone="$gone $p"
done
sleep 1
n=0
for p in $gone; do kill -0 "$p" 2>/dev/null || n=$((n+1)); done
echo "$n"
'@

# wsl.exe as root running $ReapSh for relays older than $MinAge seconds; prints how many are gone.
function Start-ReapProcess([int]$MinAge) {
    $sh = ($ReapSh -replace "`r`n", "`n").Replace('MINAGE', [string]$MinAge)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sh))
    $psi = New-Object Diagnostics.ProcessStartInfo 'wsl.exe', "-d $Distro -u root -- sh -c `"echo $b64 | base64 -d | sh`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    [Diagnostics.Process]::Start($psi)
}

function Invoke-RelayReap {
    if ($script:reapProc) {
        if (-not $script:reapProc.HasExited) {
            if (((Get-Now) - $script:reapStarted).TotalSeconds -lt 120) { return }
            try { $script:reapProc.Kill() } catch {}
            $script:reapProc = $null
            Write-Log 'relays: WSL did not answer the cleanup call within 2 min - new wsl.exe calls are hanging (FIX-030)'
            return
        }
        $n = 0; [void][int]::TryParse($script:reapProc.StandardOutput.ReadToEnd().Trim(), [ref]$n)
        $code = $script:reapProc.ExitCode; $script:reapProc = $null
        if ($code -ne 0) { Write-Log "relays: cleanup call failed (exit $code)" }
        elseif ($n -gt 0) { Write-Log "relays: ended $n leaked WSL relay process(es) (they slow down and then block new wsl.exe calls, FIX-030)" }
    }
    if ((Get-Now) -lt $script:reapNext) { return }
    $script:reapNext = (Get-Now).AddSeconds($RelayReapEverySec)
    if (-not (Test-DistroUp)) { return }
    $script:reapProc = Start-ReapProcess 300; $script:reapStarted = Get-Now
}

# FIX-020: when WSLg's display server (Weston) crashes, Linux VS Code loses its display and quits with every
# window. If VS Code windows were on screen shortly before, reopen VS Code: code-linux with no folder makes
# it restore all windows of the last session (window.restoreWindows), Claude panels included. Only if no
# VS Code process is running any more, and at most once per restart.
$script:codeSeenAt = [datetime]::MinValue; $script:westonRestartAt = $null

function Update-CodeSeen {
    $pids = [uint32[]](Get-MsrdcPids)
    if ($pids.Count -and [WH]::HasWindowTitled($pids, 'Visual Studio Code')) { $script:codeSeenAt = Get-Now }
}

function Invoke-CodeRecovery {
    if (-not $script:westonRestartAt) { return }
    if (((Get-Now) - $script:westonRestartAt).TotalSeconds -lt 15) { return }   # let WSLg and msrdc settle
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

$mon = @{ lastWin = $null; winSince = Get-Now; lastRestart = [datetime]::MinValue; triesKey = $null; tries = 0; next = Get-Now; rescues = 0; rescuedFor = $null; minLogged = $null; micLogged = $false; pidKey = $null; pidSince = [datetime]::MinValue }

# A msrdc disconnect while the microphone channel is open aborts Weston AND PulseAudio (WSLg bug,
# stderr.log: "rdpaudioin.c: rdp_audio_in_destroy: Assertion `!...IsOpen(...)' failed"): every Linux
# window closes, and audio is gone for ~2 minutes while PulseAudio restarts (FIX-023). In use = the
# WSLg mic (RDPSource) is not SUSPENDED or something is recording. If the audio server cannot be asked
# (down, restarting) that counts as in use too. Only called right before a restart, behind Test-DistroUp.
function Test-MicInUse {
    if (-not (Test-DistroUp)) { return $false }
    $src = @(& wsl.exe -d $Distro -e pactl list short sources 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { return $true }
    $rdp = $src | Where-Object { $_ -match '\tRDPSource\t' } | Select-Object -First 1
    if ($rdp -and $rdp -notmatch '\tSUSPENDED\s*$') { return $true }
    $rec = @(& wsl.exe -d $Distro -e pactl list short source-outputs 2>$null | Where-Object { "$_".Trim() })
    $rec.Count -gt 0
}

# A msrdc restart makes WSLg re-send its windows, and it drops every Linux window that is not on a
# current screen: after undocking they vanish (no window, nothing in the taskbar) until the screens
# come back (FIX-012). So before any restart, Linux windows left on a removed screen are moved onto the
# primary screen; the restart waits a pass so WSLg receives the moves. If a window will not move, the
# restart is skipped - stale clicks (FIX-009) are better than lost windows.
function Test-SafeToRestartMsrdc {
    $pids = [uint32[]](Get-MsrdcPids)
    if ($pids.Count -eq 0) { return $true }
    # A msrdc that (re)connected moments ago is still re-creating its windows; killing it then destroys
    # them for good (weston.log "rdp_rail_destroy_window: update is still pending", FIX-025).
    if (((Get-Now) - $mon.pidSince).TotalSeconds -lt $YoungMsrdcSec) { return $false }
    # Windows minimizes windows of a disconnected monitor; a minimized Linux window does not survive a
    # msrdc restart (FIX-012). Wait until none is minimized.
    $min = [WH]::MinimizedTitles($pids)
    if ($min) {
        if ($mon.minLogged -ne $min) { Write-Log "monitors: NOT restarting msrdc while Linux window(s) are minimized (they would be lost): $min"; $mon.minLogged = $min }
        return $false
    }
    $mon.minLogged = $null
    if (Test-MicInUse) {
        if (-not $mon.micLogged) { Write-Log 'monitors: NOT restarting msrdc while the microphone is in use (dictation / call) - WSLg would crash'; $mon.micLogged = $true }
        return $false
    }
    $mon.micLogged = $false
    $left = [WH]::StrandedTitles($pids)
    if (-not $left) { $mon.rescues = 0; return $true }
    if ($mon.rescues -ge 2) {
        Write-Log "monitors: NOT restarting msrdc - Linux window(s) still off-screen and would be lost: $left"
        return $false
    }
    $n = [WH]::RescueStranded($pids)
    $mon.rescues++
    Write-Log "monitors: moved $n Linux window(s) onto the main screen before restarting msrdc: $left"
    $mon.next = (Get-Now).AddSeconds(3)   # let WSLg take the new positions, then check again
    $false
}

function Invoke-MonitorSync {
    # A new msrdc = a fresh connection, which carries the current layout and re-sends every window: a live
    # change from before it is already handled (FIX-025). Also starts the young-msrdc wait above.
    $pidKey = (@(Get-MsrdcPids) | Sort-Object) -join ','
    if ($pidKey -ne $mon.pidKey) {
        if ($mon.pidKey -and $script:liveChange) { $script:liveChange = $false; Write-Log 'monitors: msrdc reconnected by itself after the screen change - no restart needed' }
        $mon.pidKey = $pidKey; $mon.pidSince = Get-Now
    }
    $win = [WH]::Layout()
    if ($win -ne $mon.lastWin) { $mon.lastWin = $win; $mon.winSince = Get-Now; return }
    if (((Get-Now) - $mon.winSince).TotalSeconds -lt $StableSec) { return }

    # Screens changed (undocked): bring Linux windows left on a removed screen to the main screen, like
    # Windows does for its own windows. Only in the first minute after a change, so a window you park
    # half off-screen yourself is left alone.
    if ($mon.lastWin -ne $mon.rescuedFor -and ((Get-Now) - $mon.winSince).TotalSeconds -lt 70) {
        $pids = [uint32[]](Get-MsrdcPids)
        $left = if ($pids.Count) { [WH]::StrandedTitles($pids) } else { '' }
        if ($left) {
            $n = [WH]::RescueStranded($pids)
            Write-Log "monitors: screens changed - moved $n Linux window(s) onto the main screen: $left"
            $mon.next = (Get-Now).AddSeconds(3)
            return
        }
        $mon.rescuedFor = $mon.lastWin
    }

    Update-WslgLayout
    # A freshly booted WSLg logs a 0x0 placeholder monitor before msrdc connects: not a real layout.
    if ($script:wslgLayout -match '(^| )-?\d+,-?\d+,0,0($| )') { return }
    # Woke from a long idle: rebuild the windows once things have settled, so they open again (FIX-017).
    if ($script:wokeAt -and ((Get-Now) - $script:wokeAt).TotalSeconds -ge $WakeSettleSec) {
        if (((Get-Now) - $mon.lastRestart).TotalSeconds -lt $CooldownSec) { $script:wokeAt = $null; return }
        if (-not (Test-SafeToRestartMsrdc)) { return }
        Write-Log ("monitors: woke after {0} min idle -> restarting msrdc so Linux windows open again" -f [int]($script:wokeIdle / 60))
        Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $mon.lastRestart = Get-Now; $script:wokeAt = $null; $script:liveChange = $false
        return
    }
    if ($script:wslgLayout -and $script:wslgLayout -eq $win -and $script:liveChange) {
        if (((Get-Now) - $mon.lastRestart).TotalSeconds -lt $CooldownSec) { return }
        if (-not (Test-SafeToRestartMsrdc)) { return }
        Write-Log "monitors: live layout change to [$win] -> restarting msrdc to rebuild Linux windows"
        Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $mon.lastRestart = Get-Now; $script:liveChange = $false
        return
    }
    if (-not $script:wslgLayout -or $script:wslgLayout -eq $win) { $mon.tries = 0; $mon.triesKey = $null; return }

    $key = "$win => $($script:wslgLayout)"
    if ($key -ne $mon.triesKey) { $mon.triesKey = $key; $mon.tries = 0 }
    if ($mon.tries -ge $MaxTries) { return }
    if (((Get-Now) - $mon.lastRestart).TotalSeconds -lt $CooldownSec) { return }
    if (-not (Test-SafeToRestartMsrdc)) { return }

    Write-Log "monitors: Windows[$win] WSLg[$($script:wslgLayout)] -> restarting msrdc (try $($mon.tries + 1))"
    Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $mon.lastRestart = Get-Now; $mon.tries++
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
    if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch {}; return 'wsl.exe did not answer within 10 s (leaked relays? FIX-030)' }
    if ($p.ExitCode -ne 0) { return "wl-copy failed, exit $($p.ExitCode) (is wl-clipboard installed in the distro?)" }
    ''
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
        if (-not $clip.outSince) { $clip.outSince = Get-Now }
        if ((Get-Now) -lt $clip.graceUntil -or ((Get-Now) - $clip.outSince).TotalMilliseconds -lt $LeaveMs) { return }
    }
    if ($fgLinux -and -not $clip.inLinux) {
        $clip.inLinux = $true
        if ($clip.pending -and (Test-DistroUp)) {
            $img = $clip.pending; $clip.pending = $null
            $why = Send-ImageToLinux $img
            if (-not $why) {
                Start-Sleep -Milliseconds $SettleMs
                $clip.handedSeq = [WH]::GetClipboardSequenceNumber(); $clip.seenSeq = $clip.handedSeq
                if ($clip.handed) { $clip.handed.Dispose() }
                $clip.handed = $img
                $clip.graceUntil = (Get-Now).AddMilliseconds($GraceMs)
                Write-Log "clipboard: handed image ($($img.Width)x$($img.Height)) to Linux as PNG"
            } else { $img.Dispose(); Write-Log "clipboard: image not handed to Linux - $why" }
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
    # A keep-alive is a wsl.exe with a wsl.exe child of the same command line: count the roots only.
    $ka = @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -like '*exec sleep infinity*' })
    $kaIds = @($ka | ForEach-Object { $_.ProcessId })
    Write-Output ("Keep-alive sessions:      " + @($ka | Where-Object { $kaIds -notcontains $_.ParentProcessId }).Count)
    Write-Output ("Restart after wake:       " + $(if ($WakeRestart) { 'on (helper-config.json wakeRestart)' } else { 'off' }))
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
# Dev Control's "Fix Linux windows" button (FIX-022): restore minimized Linux windows, move off-screen
# ones to the main screen, then restart msrdc so WSLg re-sends every window and the current monitor
# layout. Last line: "CODEWINDOWS <n>" = Linux VS Code windows on screen afterwards.
if ($Repair) {
    if (-not (Test-DistroUp)) { Write-Output 'WSL is not running - no Linux windows to fix.'; Write-Output 'CODEWINDOWS -1'; return }
    $pids = [uint32[]](Get-MsrdcPids)
    if ($pids.Count) {
        $n = [WH]::RestoreMinimized($pids)
        if ($n) { Write-Log "repair: restored $n minimized Linux window(s)"; Write-Output "Restored $n minimized Linux window(s)."; Start-Sleep -Seconds 2 }
        $left = [WH]::StrandedTitles($pids)
        if ($left) {
            $n = [WH]::RescueStranded($pids)
            Write-Log "repair: moved $n Linux window(s) onto the main screen: $left"; Write-Output "Moved $n off-screen window(s) onto the main screen."
            Start-Sleep -Seconds 2
        }
        $min = [WH]::MinimizedTitles($pids)
        if (Test-MicInUse) {
            Write-Log 'repair: NOT restarting msrdc - the microphone is in use (WSLg would crash)'
            Write-Output 'Did not reconnect WSLg: the microphone is in use (dictation or a call) and reconnecting now would crash WSLg and close every Linux window. Try again when you have stopped recording (if WSLg just crashed, its audio needs about 2 minutes to come back).'
        } elseif ($min) {
            Write-Log "repair: NOT restarting msrdc - window(s) still minimized: $min"
            Write-Output "Did not reconnect WSLg: these windows would not restore and would be lost: $min"
        } else {
            # Same rule as Test-SafeToRestartMsrdc: let a msrdc that just (re)connected finish first (FIX-025).
            $young = @(Get-Process msrdc -ErrorAction SilentlyContinue | ForEach-Object { try { ((Get-Date) - $_.StartTime).TotalSeconds } catch { 999 } } | Where-Object { $_ -lt $YoungMsrdcSec })
            if ($young.Count) { Start-Sleep -Seconds ([int]($YoungMsrdcSec - ($young | Measure-Object -Minimum).Minimum) + 1) }
            $before = [WH]::CountTitled($pids, '')
            Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log 'repair: restarted msrdc (Dev Control Fix Linux windows)'
            Write-Output 'Reconnected WSLg (msrdc): windows and monitor layout re-sent.'
            # WSLGd relaunches msrdc within seconds; the windows follow 5-15 s later (if the reconnect crashes
            # Weston - "unable to checkDescriptor", about 1 in 8 - Invoke-CodeRecovery reopens VS Code ~20 s later). Wait until as many
            # are back as were on screen before (or 35 s), so the VS Code count below is not taken too early.
            $new = [uint32[]]@()
            for ($i = 0; $i -lt 35; $i++) {
                Start-Sleep -Seconds 1
                $new = [uint32[]]@(Get-Process msrdc -ErrorAction SilentlyContinue | Where-Object { $pids -notcontains [uint32]$_.Id } | ForEach-Object { [uint32]$_.Id })
                if ($new.Count -and [WH]::CountTitled($new, '') -ge [Math]::Max(1, $before)) { break }
            }
            Start-Sleep -Seconds 2
        }
    } else { Write-Output 'WSLg is not connected right now (no msrdc) - it reconnects by itself; try again in a few seconds.' }
    $script:msrdcAt = [datetime]::MinValue
    Write-Output ('CODEWINDOWS ' + [WH]::CountTitled([uint32[]](Get-MsrdcPids), 'Visual Studio Code'))
    return
}
# Dev Control's "Fix WSL" button (FIX-030): end leaked relays now (older than 60 s, not 5 min) and say whether
# WSL answers new calls again. Last line: "RELAYS <n>" = how many ended, -1 = WSL did not answer.
if ($Reap) {
    if (-not (Test-DistroUp)) { Write-Output 'WSL is not running - nothing to fix.'; Write-Output 'RELAYS -1'; return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-ReapProcess 60
    if (-not $p.WaitForExit(90000)) {
        try { $p.Kill() } catch {}
        # Count the relays over 9p, which still answers while new sessions hang: many = they are the likely
        # cause; few = something else is stuck and only a WSL restart helps.
        $proc = "\\wsl.localhost\$Distro\proc"
        $count = @(Get-ChildItem $proc -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' } |
                   Where-Object { try { (Get-Content "$($_.FullName)\comm" -ErrorAction Stop) -eq 'Relay' } catch { $false } }).Count
        Write-Log "relays: Fix WSL - WSL did not answer within 90 s; $count relay(s) in the distro (FIX-030)"
        Write-Output "WSL is not accepting new connections right now, so the cleanup could not run from Windows ($count stuck relay process(es) in Linux)."
        if ($count -ge 20) {
            Write-Output 'In a Linux terminal that is already open, run:  for p in $(ps -eo pid=,ppid=,etimes=,comm= | awk ''$4=="Relay" && $2==1 && $3>60 {print $1}''); do [ -z "$(ps -o pid= --ppid $p)" ] && sudo kill -KILL $p; done'
            Write-Output 'If that does not help, Stop WSL and start it again.'
        } else {
            Write-Output 'That is too few to be the cause. Wait a minute and try again; if it keeps failing, Stop WSL and start it again.'
        }
        Write-Output 'RELAYS -1'
        return
    }
    $n = 0; [void][int]::TryParse($p.StandardOutput.ReadToEnd().Trim(), [ref]$n)
    if ($p.ExitCode -ne 0) { Write-Output "The cleanup failed (wsl.exe exit $($p.ExitCode))."; Write-Output 'RELAYS -1'; return }
    $slow = if ($sw.Elapsed.TotalSeconds -ge 10) { " WSL took $([int]$sw.Elapsed.TotalSeconds) s to answer - try again in a minute if pasting or explorer.exe still fail." } else { '' }
    Write-Log "relays: Fix WSL - ended $n leaked WSL relay process(es) ($([int]$sw.Elapsed.TotalMilliseconds) ms, FIX-030)"
    Write-Output $(if ($n -gt 0) { "Ended $n stuck WSL relay process(es); new WSL calls (screenshot paste, explorer.exe, clip.exe) should work again.$slow" } else { "No stuck WSL relays found - WSL answers normally.$slow" })
    Write-Output "RELAYS $n"
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
$downCheck = Get-Now
# Away = the session was locked or the PC slept since WSLg went idle (the FIX-017 wake rule needs it).
# Asleep shows as a gap between passes, in wall-clock or monotonic time (either may skip the sleep).
$script:awaySeen = $false; $lastWall = Get-Date; $lastMono = Get-Now
while ($true) {
    Start-Sleep -Milliseconds $TickMs
    try {
        if ((Get-Now) -ge $downCheck) {
            $downCheck = (Get-Now).AddSeconds(2)
            $wall = Get-Date; $mono = Get-Now
            if (($wall - $lastWall).TotalSeconds -gt 60 -or ($mono - $lastMono).TotalSeconds -gt 60) { $script:awaySeen = $true }
            $lastWall = $wall; $lastMono = $mono
            if (Get-Process LogonUI -ErrorAction SilentlyContinue) { $script:awaySeen = $true }
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
        if ((Get-Now) -ge $mon.next) { $mon.next = (Get-Now).AddSeconds($MonitorEverySec); Update-CodeSeen; Invoke-MonitorSync; Invoke-CodeRecovery }
        Invoke-KeepAliveCheck
        Invoke-RelayReap
    } catch { Write-Log "error: $($_.Exception.Message)" }
}
