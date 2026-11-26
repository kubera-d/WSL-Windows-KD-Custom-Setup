# Core.ps1 - Windows-side logic for Dev Control.
# Dot-sourced by the UI (DevControl.ps1) and by every background runspace.
# RULE: nothing in here may run a Linux command unless Test-DcWslRunning says the
# distro is up (Invoke-DcLinux enforces this) - any wsl.exe call that executes
# something inside Linux boots WSL. Only Start-DcWslBoot boots on purpose.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

$script:DcAppDir  = $PSScriptRoot
$script:DcDataDir = Join-Path $env:LOCALAPPDATA 'DevControl'
if (-not (Test-Path $script:DcDataDir)) { New-Item -ItemType Directory -Force -Path $script:DcDataDir | Out-Null }

$script:DcComposeFiles = @('compose.yaml', 'compose.yml', 'docker-compose.yaml', 'docker-compose.yml')

# ---------------------------------------------------------------- settings / logging

# The user's default WSL distro, read from the registry (NOT from wsl.exe: any wsl.exe call that
# runs something could boot WSL). Falls back to 'Ubuntu'. Cached per runspace.
function Get-DcDefaultDistro {
    if ($script:DcDefaultDistro) { return $script:DcDefaultDistro }
    $name = ''
    try {
        $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        $id = [string](Get-ItemProperty -Path $lxss -Name 'DefaultDistribution' -ErrorAction Stop).DefaultDistribution
        if ($id) { $name = [string](Get-ItemProperty -Path "$lxss\$id" -Name 'DistributionName' -ErrorAction Stop).DistributionName }
    } catch { }
    if (-not $name) { $name = 'Ubuntu' }
    $script:DcDefaultDistro = $name
    $name
}

# Expands %VARS%; a relative path is taken relative to the app folder.
function Resolve-DcAppPath([string]$Path) {
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $script:DcAppDir $p }
    $p
}

# Keys where an empty value in settings.json means "use the default".
$script:DcDefaultWhenEmpty = @('distro', 'modesDir', 'wslConfigPath')

function Get-DcSettings {
    $s = [ordered]@{
        distro                  = ''            # '' = the default WSL distro (registry), else Ubuntu
        projectsRoot            = ''            # Linux path, e.g. /home/<you>/projects - no default
        modesDir                = 'modes'       # relative = next to the app
        wslConfigPath           = '%USERPROFILE%\.wslconfig'
        codePath                = ''
        codeFlavor              = 'linux'
        trayIcon                = $true
        minimizeToTray          = $true
        closeToTray             = $false
        keepAlive               = $true
        statusRefreshSeconds    = 3
        wslQuerySeconds         = 30            # with the WSL VM up, how often the status poll runs wsl.exe
        containerRefreshSeconds = 10
        projectRefreshSeconds   = 30
        cleanerEnabled          = $true         # stop stale dev servers / leftover browsers, close leftover tabs
        cleanerIdleHours        = 4
        cleanerCheckMinutes     = 10
        cleanerDryRun           = $false        # true = only log what it would do
        cleanerChromePort       = 9222          # the automation Chrome whose leftover tabs it closes
        cleanerKeepPorts        = @()           # listening ports never stopped
        cleanerKeepTabs         = @()           # URL patterns (-like) never closed
        cleanerServerPrograms   = @('node', 'workerd', 'python', 'pythonw', 'bun', 'deno', 'php', 'ruby')
        kernelPoolWarnGB        = 6             # one tray warning per Windows start above this; 0 = off
    }
    $path = Join-Path $script:DcAppDir 'settings.json'
    if (Test-Path $path) {
        try {
            $j = Get-Content -Raw -Path $path | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                if ($script:DcDefaultWhenEmpty -contains $p.Name -and -not ([string]$p.Value).Trim()) { continue }
                $s[$p.Name] = $p.Value
            }
        } catch { Write-DcLog "settings.json is invalid, using defaults: $($_.Exception.Message)" }
    }
    if (-not $s.distro) { $s.distro = Get-DcDefaultDistro }
    $s.projectsRoot  = ([string]$s.projectsRoot).Trim()
    $s.modesDir      = Resolve-DcAppPath ([string]$s.modesDir)
    $s.wslConfigPath = [Environment]::ExpandEnvironmentVariables([string]$s.wslConfigPath)
    [pscustomobject]$s
}

$script:DcNoProjectsRoot = 'projectsRoot is not set - set projectsRoot in settings.json (a Linux path such as /home/<you>/projects) and restart Dev Control.'

# Returns projectsRoot without a trailing slash; throws a clear message when it is not configured.
function Get-DcProjectsRoot {
    $root = (Get-DcSettings).projectsRoot.TrimEnd('/')
    if (-not $root) { throw $script:DcNoProjectsRoot }
    $root
}

function Write-DcFile([string]$Name, [string]$Line) {
    $path = Join-Path $script:DcDataDir $Name
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if ((Test-Path $path) -and (Get-Item $path).Length -gt 2MB) { Move-Item -Force $path "$path.old" }
            [IO.File]::AppendAllText($path, $Line + "`r`n")
            return
        } catch { Start-Sleep -Milliseconds 30 }
    }
}

function Write-DcLog([string]$Message) {
    Write-DcFile 'app.log' ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message)
}

# Every wsl.exe invocation is recorded. Kind QUERY = cannot boot WSL, LINUX/BOOT = runs inside Linux.
function Write-DcCallLog([string]$Kind, [string]$Arguments) {
    Write-DcFile 'wsl-calls.log' ("{0:yyyy-MM-dd HH:mm:ss.fff}  [{1}]  {2,-5}  {3}" -f (Get-Date), $PID, $Kind, $Arguments)
}

# ---------------------------------------------------------------- process helpers

# Runs a console program with no window (the app has no console, so a plain `& exe`
# would pop one up) and captures output.
function Invoke-DcProcess([string]$File, [string]$Arguments, [int]$TimeoutSec = 60) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $File, $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['WSL_UTF8'] = '1'
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill() } catch { }
        throw "Timed out after ${TimeoutSec}s: $File $Arguments"
    }
    $p.WaitForExit()
    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Out      = ($out.Result -replace "`0", '')
        Err      = ($err.Result -replace "`0", '')
    }
}

# Fire-and-forget, no window, no redirection (for GUI programs like VS Code whose
# children would otherwise hold our pipes open).
function Start-DcDetached([string]$File, [string]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $File, $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.EnvironmentVariables['WSL_UTF8'] = '1'
    [Diagnostics.Process]::Start($psi)
}

function ConvertTo-DcBashLiteral([string]$s) { "'" + $s.Replace("'", "'\''") + "'" }

# ---------------------------------------------------------------- WSL state (never boots)

function Test-DcWslRunning {
    if ($env:DEVCONTROL_FAKE_STOPPED -eq '1') { return $false }   # used by the self-test
    $s = Get-DcSettings
    Write-DcCallLog 'QUERY' '--list --running --quiet'
    $r = Invoke-DcProcess 'wsl.exe' '--list --running --quiet' 20
    $names = @($r.Out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ($names -contains $s.distro)
}

function Get-DcWslMemory {
    $p = Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { [int64]$p.WorkingSet64 } else { [int64]0 }
}

# True while the WSL VM runs. No VM = no distro running, known without starting wsl.exe (FIX-033).
function Test-DcWslVm { [bool](Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue) }

function ConvertTo-DcNormalizedConfig([string]$Text) {
    $lines = $Text -split "`r?`n" | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') -and -not $_.StartsWith(';') } |
        ForEach-Object { $_ -replace '\s*=\s*', '=' }
    ($lines -join "`n").ToLowerInvariant()
}

function Get-DcConfigValue([string]$Text, [string]$Key) {
    $m = [regex]::Match($Text, "(?im)^\s*$Key\s*=\s*(.+?)\s*$")
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

function Get-DcModes {
    $s = Get-DcSettings
    if (-not (Test-Path $s.modesDir)) { return @() }
    @(Get-ChildItem -Path $s.modesDir -Filter '*.wslconfig' | Sort-Object Name | ForEach-Object { $_.BaseName })
}

# Current mode = the mode file whose content matches .wslconfig ('custom' if none, 'none' if missing).
function Get-DcCurrentMode {
    $s = Get-DcSettings
    if (-not (Test-Path $s.wslConfigPath)) {
        return [pscustomobject]@{ Mode = 'none'; Memory = ''; Processors = '' }
    }
    $text = Get-Content -Raw -Path $s.wslConfigPath
    $cur  = ConvertTo-DcNormalizedConfig $text
    $mode = 'custom'
    foreach ($m in Get-DcModes) {
        $mt = Get-Content -Raw -Path (Join-Path $s.modesDir "$m.wslconfig")
        if ((ConvertTo-DcNormalizedConfig $mt) -eq $cur) { $mode = $m; break }
    }
    [pscustomobject]@{
        Mode       = $mode
        Memory     = Get-DcConfigValue $text 'memory'
        Processors = Get-DcConfigValue $text 'processors'
    }
}

function Find-DcKeepAlive {
    @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*exec sleep infinity*' })
}

# The background status check. wsl.exe runs only while the WSL VM is up and $Query is set (the UI asks every
# wslQuerySeconds, and on every poll until the distro reports running); without the VM, Running is $false
# with no process started; VM up but not asked: Running = $null (unchanged). FIX-033.
function Get-DcStatus([bool]$Query = $true) {
    $vm = Test-DcWslVm
    $asked = ($env:DEVCONTROL_FAKE_STOPPED -eq '1') -or ($vm -and $Query)
    $running = if ($asked) { Test-DcWslRunning } elseif ($vm) { $null } else { $false }
    $mode = Get-DcCurrentMode
    [pscustomobject]@{
        Running        = $running
        Queried        = $asked
        MemoryBytes    = if ($running -ne $false -and $vm) { Get-DcWslMemory } else { [int64]0 }
        Mode           = $mode.Mode
        ModeMemory     = $mode.Memory
        ModeProcessors = $mode.Processors
    }
}

# ---------------------------------------------------------------- mode / lifecycle

function Set-DcMode([string]$Mode) {
    $s = Get-DcSettings
    if ((Get-DcModes) -notcontains $Mode) { throw "Unknown mode '$Mode' (no $Mode.wslconfig in $($s.modesDir))" }
    if ((Get-DcCurrentMode).Mode -eq 'custom') {
        # .wslconfig matches no mode file: keep a copy before overwriting it.
        $bak = Join-Path $script:DcDataDir ("wslconfig.backup-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
        Copy-Item -Force $s.wslConfigPath $bak
        Write-DcLog "Backed up custom .wslconfig to $bak"
    }
    Copy-Item -Force -Path (Join-Path $s.modesDir "$Mode.wslconfig") -Destination $s.wslConfigPath
    Write-DcLog "Mode set to $Mode"
}

function Wait-DcWslState([bool]$Running, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Test-DcWslRunning) -eq $Running) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# While this file is fresh (< 2 min), the WSLg Helper does not touch \\wsl.localhost: opening any
# path there boots the distro straight back up (FIX-010 in docs/fixes.md). Start-DcWslBoot removes it.
$script:DcStopMarker = Join-Path $script:DcDataDir 'wsl-stopping'
function Set-DcStopMarker { try { [IO.File]::WriteAllText($script:DcStopMarker, (Get-Date).ToString('o')) } catch { } }

# Explorer windows showing a Linux folder (\\wsl.localhost\... or \\wsl$\...): seconds after wsl --shutdown
# Explorer refreshes them and that boots the distro straight back up - no wsl.exe involved (FIX-029).
function Get-DcLinuxExplorerWindows {
    try { @((New-Object -ComObject Shell.Application).Windows() | Where-Object { "$($_.LocationURL)" -match '^file://wsl(\.localhost|\$)/' }) } catch { @() }
}
function Close-DcLinuxExplorerWindows {
    $n = 0
    foreach ($w in @(Get-DcLinuxExplorerWindows)) { try { $w.Quit(); $n++ } catch { } }
    $n
}

# Down = no distro listed as running AND the VM process is gone (that is what frees memory/CPU).
# A hung Linux kernel makes even `wsl --list --running` time out: that is "not down" (and noted in
# $script:DcWslHung), not an error - otherwise Stop WSL failed without offering the force stop (FIX-026).
$script:DcWslHung = $false
function Test-DcWslDown {
    if (-not (Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue)) {
        try { return -not (Test-DcWslRunning) } catch { $script:DcWslHung = $true; return $false }
    }
    $false
}

function Wait-DcWslDown([int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-DcWslDown) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# True if WSL stays down for $Sec seconds (something opening \\wsl.localhost or running wsl.exe
# right after a shutdown boots it again).
function Test-DcWslStaysDown([int]$Sec) {
    $deadline = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1000
        if (-not (Test-DcWslDown)) { return $false }
    }
    return $true
}

# Windows-side WSL clients with their parent process, for the log when WSL comes back by itself.
function Get-DcWslClients {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $byId = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
    @($procs | Where-Object { @('wsl.exe', 'wslhost.exe', 'wslrelay.exe', 'msrdc.exe') -contains $_.Name.ToLowerInvariant() } | ForEach-Object {
        $par = $byId[[int]$_.ParentProcessId]
        '{0} {1} (parent {2})' -f $_.Name, $_.ProcessId, $(if ($par) { "$($par.Name) $($par.ProcessId)" } else { '?' })
    })
}

# wsl --shutdown, then wsl --shutdown --force; each must leave WSL down for 8 s. Throws
# 'WSL did not stop...' otherwise - the UI then offers Stop-DcWslForce.
function Stop-DcWsl {
    $notes = @()
    $closed = 0
    $script:DcWslHung = $false
    foreach ($a in @('--shutdown', '--shutdown --force')) {
        # WSL no longer answers at all (hung kernel): a second shutdown cannot help either - go straight
        # to the force stop the UI offers on 'WSL did not stop'.
        if ($script:DcWslHung) { $notes += 'WSL is not responding (wsl.exe --list timed out)'; break }
        Set-DcStopMarker
        $n = Close-DcLinuxExplorerWindows
        if ($n) { $closed += $n; Write-DcLog "Closed $n Explorer window(s) showing Linux folders (they would start WSL again)" }
        Write-DcCallLog 'SHUT' $a
        try {
            $r = Invoke-DcProcess 'wsl.exe' $a 45
            if ($r.ExitCode -ne 0) { $notes += "wsl $a exited $($r.ExitCode): $(($r.Err + $r.Out).Trim())" }
        } catch { $notes += $_.Exception.Message }
        if (Wait-DcWslDown 20) {
            if (Test-DcWslStaysDown 8) {
                Write-DcLog "WSL shut down (wsl $a)"
                $msg = $(if ($a -eq '--shutdown') { 'WSL shut down.' } else { 'WSL shut down (forced).' })
                if ($closed) { $msg += " Closed $closed Explorer window(s) on Linux folders." }
                return $msg
            }
            $notes += "WSL started again right after wsl $a"
            Write-DcLog ("WSL started again right after wsl $a. WSL clients now: " + ((Get-DcWslClients) -join '; ') +
                "; Explorer windows on Linux folders: $(@(Get-DcLinuxExplorerWindows).Count)")
        } else {
            $notes += "still running 20s after wsl $a"
        }
    }
    throw ('WSL did not stop: ' + ($notes -join '; '))
}

# Elevated-script fragment (starts with a blank line, see CLAUDE.md): a VM that did not stop cleanly leaves its
# mirrored-mode HNS networks ("FSE Switch (<adapter>)", Type Mirrored) behind; the next start then fails
# "ConfigureNetworking/0x8007054f ... falling back to networkingMode None" - no network in Linux (FIX-028).
# WSL recreates them on start, so remove only those.
$script:DcHnsCleanup = @'

$cur = $null; $fse = $null
foreach ($l in (& hnsdiag.exe list networks 2>&1)) {
    if ("$l" -match '^Network : ([0-9A-Fa-f-]{36})') { $cur = $Matches[1] }
    elseif ($cur -and "$l" -match '^\s+Name\s+: FSE Switch') { $fse = $cur }
    elseif ($cur -and "$l" -match '^\s+Type\s+: Mirrored' -and $fse -eq $cur) { & hnsdiag.exe delete networks $cur | Out-Null; "deleted stale HNS network $cur"; $cur = $null }
}
'@

# networkingMode from .wslconfig ([wsl2] networkingMode=...), 'nat' when unset. Comment lines are ignored.
function Get-DcNetworkingMode {
    $s = Get-DcSettings
    $mode = 'nat'
    if (Test-Path -LiteralPath $s.wslConfigPath) {
        foreach ($l in (Get-Content -LiteralPath $s.wslConfigPath -ErrorAction SilentlyContinue)) {
            if ($l -match '^\s*networkingMode\s*=\s*([A-Za-z]+)') { $mode = $Matches[1].ToLowerInvariant() }
        }
    }
    $mode
}

# Shell test: Linux has a default route (IPv4 or IPv6). Without one, nothing in Linux reaches the internet -
# Claude Code shows getaddrinfo EAI_AGAIN / chats do not load, Remote Control cannot connect (FIX-028).
$script:DcNetTest = '{ ip -4 route show default; ip -6 route show default; } 2>/dev/null | grep -q .'
$script:DcNoNetworkMsg = 'WARNING: WSL started WITHOUT A NETWORK (no default route in Linux; mirrored networking failed - FIX-028).'

# Repairs FIX-028 with WSL fully down (the caller stops it): delete stale FSE Switch networks, then restart the
# Host Network Service - the step that worked when the deletion alone did not. Needs admin (UAC).
function Repair-DcWslNetwork {
    if (-not (Test-DcWslDown)) { throw 'WSL is still running - stop it before repairing its network.' }
    Set-DcStopMarker
    $script = Join-Path $script:DcDataDir 'repair-wsl-network.ps1'
    $out = Join-Path $script:DcDataDir 'repair-wsl-network.log'
    ('$ErrorActionPreference = ''Continue''' + "`r`n" + '& {' + $script:DcHnsCleanup + @'

Stop-Service hns -Force
Start-Service hns
"hns: $((Get-Service hns).Status)"
} *>&1 | Out-File -FilePath $args[0] -Encoding ASCII
'@) | Set-Content -Path $script -Encoding ASCII
    Remove-Item -Force -ErrorAction SilentlyContinue $out
    Write-DcCallLog 'NETFIX' 'hnsdiag delete <stale FSE Switch networks> / restart hns (elevated)'
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -PassThru `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" `"$out`""
    } catch { throw "Network repair cancelled ($($_.Exception.Message))" }
    if (-not $p.WaitForExit(90000)) { throw 'Network repair did not finish within 90 s.' }
    $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() })
    Write-DcLog ('Network repair: ' + ($lines -join '; '))
    if (-not ($lines -match '^hns: Running$')) { throw ('Host Network Service did not restart: ' + ($lines -join '; ')) }
    'Reset WSL networking (Host Network Service restarted' + $(if ($lines -match '^deleted') { ", $(@($lines -match '^deleted').Count) stale network(s) removed" } else { '' }) + ').'
}

# Last resort (asks for admin rights via UAC): end the WSL VM through the Host Compute Service
# (hcsdiag kill), then restart wslservice.exe if the VM is still there OR wsl.exe does not answer:
# a `wsl --shutdown --force` that never returns can leave the service hung with no VM at all - every
# wsl.exe call then waits forever, so WSL can neither stop nor start (FIX-032). Task Manager cannot
# end vmmemWSL - the hypervisor owns it. Unsaved work in Linux is lost.
function Stop-DcWslForce {
    Set-DcStopMarker
    $script = Join-Path $script:DcDataDir 'force-stop-wsl.ps1'
    $out = Join-Path $script:DcDataDir 'force-stop-wsl.log'
    ('$ErrorActionPreference = ''Continue''' + "`r`n" + '& {' + @'

$ids = @(& hcsdiag.exe list 2>$null | ForEach-Object { if ($_ -match '([0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}).*\bWSL\s*$') { $Matches[1] } })
foreach ($id in $ids) { & hcsdiag.exe kill $id | Out-Null; "killed WSL VM $id" }
Start-Sleep -Seconds 5
$q = Start-Process -FilePath 'wsl.exe' -ArgumentList '--list --quiet' -WindowStyle Hidden -PassThru
$hung = -not $q.WaitForExit(15000)
if ($hung) { try { $q.Kill() } catch { } }
$vm = [bool](Get-Process -Name vmmemWSL -ErrorAction SilentlyContinue)
if ($hung -or $vm) {
    Stop-Process -Name wslservice -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service WSLService -ErrorAction SilentlyContinue
    'restarted the WSL service (' + $(if ($hung) { 'wsl.exe did not answer' } else { 'VM still there' }) + ')'
}
'@ + $script:DcHnsCleanup + @'

} *>&1 | Out-File -FilePath $args[0] -Encoding ASCII
'@) | Set-Content -Path $script -Encoding ASCII
    Remove-Item -Force -ErrorAction SilentlyContinue $out
    Write-DcCallLog 'FORCE' 'hcsdiag kill <WSL VM> / restart wslservice if VM left or hung / HNS cleanup (elevated)'
    try {
        $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -PassThru `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`" `"$out`""
    } catch { throw "Force stop cancelled ($($_.Exception.Message))" }
    [void]$p.WaitForExit(90000)
    $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() })
    if ($lines.Count) { Write-DcLog ('Force stop: ' + ($lines -join '; ')) }
    $script:DcWslHung = $false
    if (-not (Wait-DcWslDown 30)) {
        if ($script:DcWslHung) { throw 'WSL still does not answer after the force stop restarted its service. Restart Windows (Start > Power > Restart).' }
        throw 'WSL is still running after the force stop. Restart Windows (Start > Power > Restart) - a normal restart works, no need to hold the power button.'
    }
    Write-DcLog 'WSL force-stopped'
    'WSL force-stopped.' + $(if (@($lines -match '^restarted the WSL service').Count) { ' The WSL service was restarted.' } else { '' })
}

# The ONLY function that boots WSL on purpose.
function Start-DcWslBoot {
    $s = Get-DcSettings
    $msgs = @()
    Remove-Item -Force -ErrorAction SilentlyContinue $script:DcStopMarker
    # A hung WSL service (FIX-032) makes every wsl.exe wait forever, the boot included. Say so instead of a bare
    # timeout: the UI offers the force stop on 'WSL is not responding', and that restarts the service.
    try { [void](Test-DcWslRunning) } catch { throw "WSL is not responding ($($_.Exception.Message))." }
    if ($s.keepAlive) {
        # A long-lived hidden wsl.exe session keeps the distro from idling out after
        # the last terminal/VS Code window closes. wsl --shutdown ends it.
        if ((Find-DcKeepAlive).Count -eq 0) {
            $a = "-d $($s.distro) -- bash -lc `"exec sleep infinity`""
            Write-DcCallLog 'BOOT' $a
            $psi = New-Object System.Diagnostics.ProcessStartInfo 'wsl.exe', $a
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            [void][Diagnostics.Process]::Start($psi)
            $msgs += 'Started keep-alive session.'
        }
        if (-not (Wait-DcWslState $true 90)) { throw "$($s.distro) did not start within 90s" }
    } else {
        $a = "-d $($s.distro) -- bash -lc true"
        Write-DcCallLog 'BOOT' $a
        $r = Invoke-DcProcess 'wsl.exe' $a 120
        if ($r.ExitCode -ne 0) { throw "WSL start failed ($($r.ExitCode)): $($r.Err)" }
    }
    $msgs += "$($s.distro) is running."
    # The WSLg Helper (repo install, optional) runs only while WSL runs and exits when it stops.
    if (Get-ScheduledTask -TaskName 'WSLg Helper' -ErrorAction SilentlyContinue) {
        try { Start-ScheduledTask -TaskName 'WSLg Helper' -ErrorAction Stop; $msgs += 'WSLg Helper started.' }
        catch { $msgs += "WARNING: WSLg Helper did not start: $($_.Exception.Message)" }
    }
    # Wait for dockerd (systemd starts it a moment after boot).
    $r = Invoke-DcLinux 'for i in $(seq 1 60); do docker info >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1' 90
    $msgs += if ($r.ExitCode -eq 0) { 'Docker is ready.' } else { 'WARNING: Docker did not respond within 60s.' }
    # Mirrored networking can fail at boot and fall back to none without telling anyone (FIX-028).
    if ((Get-DcNetworkingMode) -ne 'none') {
        $r = Invoke-DcLinux ('for i in $(seq 1 15); do ' + $script:DcNetTest + ' && exit 0; sleep 1; done; exit 1') 40
        if ($r.ExitCode -ne 0) { $msgs += $script:DcNoNetworkMsg }
    }
    Write-DcLog ($msgs -join ' ')
    $msgs -join ' '
}

# ---------------------------------------------------------------- Linux commands (guarded)

function Invoke-DcLinux([string]$Script, [int]$TimeoutSec = 120) {
    $s = Get-DcSettings
    if (-not (Test-DcWslRunning)) {
        throw 'WSL is stopped - refusing to run a Linux command (it would boot WSL).'
    }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Script -replace "`r`n", "`n")))
    $a = "-d $($s.distro) -- bash -lc `"echo $b64 | base64 -d | bash`""
    $first = ($Script -split "`n")[0]
    Write-DcCallLog 'LINUX' $first
    Invoke-DcProcess 'wsl.exe' $a $TimeoutSec
}

function Get-DcLinuxInfo {
    $r = Invoke-DcLinux 'nproc; awk ''/MemTotal/{print $2*1024}'' /proc/meminfo' 30
    $l = @($r.Out -split "`r?`n" | Where-Object { $_ })
    [pscustomobject]@{ Cpus = [int]$l[0]; MemBytes = [int64][double]$l[1] }
}

# ---------------------------------------------------------------- compose projects

# EVERY folder under projectsRoot is a project (new folders are picked up on the next refresh;
# projects.json only adds metadata - group, mode, tools, hidden - it is not a list of what exists).
# Exception: entries with a "path" are listed from that folder (outside projectsRoot). A Linux path is
# read in Linux; a Windows path is read on Windows (Get-DcWindowsProjects), never through /mnt.
# Reports the compose file (in the folder, or in its configured composeDir), git-worktree details
# and last activity so the UI can classify them.
function Get-DcProjects {
    $root = Get-DcProjectsRoot
    $cfg = Get-DcProjectConfig
    $cfgLines = @($cfg.Keys | ForEach-Object {
        $sub = if ($cfg[$_].PSObject.Properties['composeDir']) { [string]$cfg[$_].composeDir } else { '' }
        $pp = Get-DcProjectPath $_ $cfg
        # ':win' = listed on the Windows side: Linux skips the name (it is never a directory there)
        $lp = if (Test-DcWindowsPath $pp) { ':win' } elseif ($pp) { ConvertTo-DcLinuxPath $pp } else { '' }
        # 0x1f, not tab: read collapses runs of IFS whitespace, so an empty composeDir would eat the path
        $_ + [char]0x1f + $sub + [char]0x1f + $lp
    }) -join "`n"
    $script = @'
root=__ROOT__
declare -A sub xp
while IFS=$'\x1f' read -r n s p; do [ -n "$n" ] && { sub["$n"]="$s"; [ -n "$p" ] && xp["$n"]="$p"; }; done <<'CFG'
__CFG__
CFG
emit() {
  local n="$1" d="$2" s cd cf="" cname="" wt="" parent="" br="" dirty="" ahead="" last="" gd pdir pb f
  s="${sub[$n]}"; cd="$d${s:+/$s}"
  for f in __FILES__; do [ -f "$cd/$f" ] && { cf="$cd/$f"; break; }; done
  if [ -n "$cf" ]; then
    cname=$(awk '/^name:/{gsub(/["\047]/,"",$2); print $2; exit}' "$cf")
    [ -n "$cname" ] || cname=$(basename "$cd" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')
  fi
  if [ -f "$d/.git" ]; then
    gd=$(sed -n 's/^gitdir: //p' "$d/.git"); pdir="${gd%/.git/worktrees/*}"
    if [ "$pdir" != "$gd" ]; then
      wt=1; parent=$(basename "$pdir"); pb=$(git -C "$pdir" symbolic-ref --short HEAD 2>/dev/null)
      br=$(git -C "$d" branch --show-current 2>/dev/null)
      dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)
      ahead=$(git -C "$d" rev-list --count "$pb..HEAD" 2>/dev/null)
    fi
  fi
  [ -e "$d/.git" ] && last=$(git -C "$d" log -1 --format=%ct 2>/dev/null)
  [ -n "$last" ] || last=$(find "$d" -maxdepth 3 -type f -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/.git/*' -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
  printf 'P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$cd" "$cf" "$cname" "$wt" "$parent" "$br" "$dirty" "$ahead" "$last" "$d"
}
for d in "$root"/*/; do n=$(basename "$d"); [ -n "${xp[$n]}" ] || emit "$n" "${d%/}"; done
for n in "${!xp[@]}"; do [ -d "${xp[$n]}" ] && emit "$n" "${xp[$n]}"; done
printf 'J\t'; docker compose ls --all --format json 2>/dev/null | tr -d '\n'; echo
'@
    $script = $script.Replace('__ROOT__', (ConvertTo-DcBashLiteral $root)).Replace('__FILES__', ($script:DcComposeFiles -join ' ')).Replace('__CFG__', $cfgLines)
    $r = Invoke-DcLinux $script 90
    if ($r.ExitCode -ne 0) { throw "Listing projects failed: $($r.Err)" }

    $status = @{}   # compose dir -> compose status
    $lines = @($r.Out -split "`r?`n")
    $json = $lines | Where-Object { $_.StartsWith("J`t") } | Select-Object -First 1
    if ($json -and $json.Length -gt 2 -and $json.Substring(2).Trim()) {
        foreach ($c in @($json.Substring(2) | ConvertFrom-Json)) {
            foreach ($cf in ($c.ConfigFiles -split ',')) { $status[($cf.Trim() -replace '/[^/]+$', '')] = $c.Status }
        }
    }
    $linux = @($lines | Where-Object { $_.StartsWith("P`t") } | ForEach-Object {
        $f = $_.Split("`t")
        [pscustomobject]@{
            Name        = $f[1]
            Dir         = $f[11]
            ComposeDir  = $f[2]
            ComposeFile = $f[3]
            Compose     = [bool]$f[3]
            ComposeName = $f[4]
            Worktree    = $f[5] -eq '1'
            Parent      = $f[6]
            Branch      = $f[7]
            Dirty       = if ($f[8]) { [int]$f[8] } else { 0 }
            Ahead       = if ($f[9]) { [int]$f[9] } else { 0 }
            LastActive  = if ($f[10]) { [int64]$f[10] } else { [int64]0 }
            Status      = if (-not $f[3]) { 'no compose file' } elseif ($status[$f[2]]) { $status[$f[2]] } else { 'down' }
        }
    })
    @(@($linux) + @(Get-DcWindowsProjects $cfg $status) | Sort-Object Name)
}

# Newest file mtime (unix seconds) up to 3 levels down, skipping dependency and git folders: the
# Windows twin of the Linux `find -maxdepth 3` fallback for folders without git.
function Get-DcNewestFileTime([string]$Dir) {
    $best = [datetime]::MinValue
    $level = @($Dir)
    for ($depth = 0; $depth -lt 3 -and $level.Count; $depth++) {
        $next = @()
        foreach ($d in $level) {
            try { $items = [IO.Directory]::GetFileSystemEntries($d) } catch { continue }
            foreach ($i in $items) {
                $leaf = [IO.Path]::GetFileName($i)
                if ([IO.Directory]::Exists($i)) {
                    if ($leaf -notin @('node_modules', '.venv', '.git')) { $next += $i }
                } else {
                    $t = [IO.File]::GetLastWriteTimeUtc($i)
                    if ($t -gt $best) { $best = $t }
                }
            }
        }
        $level = $next
    }
    if ($best -eq [datetime]::MinValue) { return [int64]0 }
    [int64]([DateTimeOffset]$best).ToUnixTimeSeconds()
}

# Projects whose projects.json "path" is a Windows path, read on Windows (git.exe and the file system)
# so they list while WSL is stopped and a refresh never crosses the /mnt bridge. Same object shape as
# Get-DcProjects; Dir / ComposeDir / ComposeFile are the Linux (/mnt) form, which is what a compose run
# and the container list use. $ComposeStatus: compose dir -> status, from the Linux listing (if any).
function Get-DcWindowsProjects($Config = $null, $ComposeStatus = @{}) {
    if ($null -eq $Config) { $Config = Get-DcProjectConfig }
    if ($null -eq $ComposeStatus) { $ComposeStatus = @{} }
    $git = Get-Command 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $gitExe = if ($git) { $git.Source } else { '' }
    $runGit = {
        param([string]$Dir, [string]$GitArgs)
        if (-not $gitExe) { return '' }
        try {
            $r = Invoke-DcProcess $gitExe ("-C `"$Dir`" " + $GitArgs) 20
            if ($r.ExitCode -eq 0) { return ([string]$r.Out).Trim() }
        } catch { }
        ''
    }
    $out = @()
    foreach ($n in @($Config.Keys)) {
        $pp = Get-DcProjectPath $n $Config
        if (-not (Test-DcWindowsPath $pp)) { continue }
        $d = $pp.TrimEnd('\', '/')
        if ($d -match '^[A-Za-z]:$') { $d += '\' }
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        $e = $Config[$n]
        $sub = if ($e.PSObject.Properties['composeDir']) { ([string]$e.composeDir).Trim('/', '\') } else { '' }
        $cdW = if ($sub) { Join-Path $d $sub } else { $d }
        $cfW = ''
        foreach ($f in $script:DcComposeFiles) { $c = Join-Path $cdW $f; if (Test-Path -LiteralPath $c -PathType Leaf) { $cfW = $c; break } }
        $cname = ''
        if ($cfW) {
            $m = Select-String -LiteralPath $cfW -Pattern '^name:\s*["'']?([^"''\s]+)' | Select-Object -First 1
            $cname = if ($m) { $m.Matches[0].Groups[1].Value } else { ((Split-Path $cdW -Leaf).ToLower() -replace '[^a-z0-9_-]', '') }
        }
        $wt = $false; $parent = ''; $br = ''; $dirty = 0; $ahead = 0; $last = [int64]0
        $dotGit = Join-Path $d '.git'
        if (Test-Path -LiteralPath $dotGit -PathType Leaf) {
            $gd = ''
            try { $gd = ([string](Get-Content -LiteralPath $dotGit -TotalCount 1)) -replace '^gitdir:\s*', '' } catch { }
            $gdN = $gd.Replace('\', '/')
            $i = $gdN.IndexOf('/.git/worktrees/')
            if ($i -gt 0) {
                $pdir = $gdN.Substring(0, $i)
                $wt = $true; $parent = Split-Path $pdir -Leaf
                $pb = & $runGit $pdir 'symbolic-ref --short HEAD'
                $br = & $runGit $d 'branch --show-current'
                $st = & $runGit $d 'status --porcelain'
                $dirty = @($st -split "`r?`n" | Where-Object { $_ }).Count
                if ($pb) { $a = & $runGit $d "rev-list --count $pb..HEAD"; if ($a -match '^\d+$') { $ahead = [int]$a } }
            }
        }
        if (Test-Path -LiteralPath $dotGit) {
            $ct = & $runGit $d 'log -1 --format=%ct'
            if ($ct -match '^\d+$') { $last = [int64]$ct }
        }
        if (-not $last) { $last = Get-DcNewestFileTime $d }
        $cdL = ConvertTo-DcLinuxPath $cdW
        $out += [pscustomobject]@{
            Name        = $n
            Dir         = ConvertTo-DcLinuxPath $d
            ComposeDir  = $cdL
            ComposeFile = if ($cfW) { ConvertTo-DcLinuxPath $cfW } else { '' }
            Compose     = [bool]$cfW
            ComposeName = $cname
            Worktree    = $wt
            Parent      = $parent
            Branch      = $br
            Dirty       = $dirty
            Ahead       = $ahead
            LastActive  = $last
            Status      = if (-not $cfW) { 'no compose file' } elseif ($ComposeStatus[$cdL]) { $ComposeStatus[$cdL] } else { 'down' }
        }
    }
    $out   # callers wrap in @()
}

# Is this project's folder a Windows path (projects.json "path")?
function Test-DcWindowsProject([string]$Project, $Config = $null) { Test-DcWindowsPath (Get-DcProjectPath $Project $Config) }

function Save-DcProjectCache($Projects) {
    try { ConvertTo-Json -InputObject @($Projects) | Set-Content -Path (Join-Path $script:DcDataDir 'projects-cache.json') -Encoding UTF8 } catch { }
}

function Get-DcProjectCache {
    $p = Join-Path $script:DcDataDir 'projects-cache.json'
    if (-not (Test-Path $p)) { return @() }
    try { @(Get-Content -Raw $p | ConvertFrom-Json) } catch { @() }
}

function Assert-DcProjectName([string]$Project) {
    if (-not $Project -or $Project -match '[/\\]' -or $Project -eq '.' -or $Project -eq '..') { throw "Invalid project name '$Project'" }
}

# A Windows path (C:\src\x) as Linux sees it (/mnt/c/src/x); Linux paths pass through.
function ConvertTo-DcLinuxPath([string]$Path) {
    if ($Path -match '^([A-Za-z]):[\\/]?(.*)$') { return ("/mnt/$($Matches[1].ToLower())/" + ($Matches[2] -replace '\\', '/')).TrimEnd('/') }
    $Path.TrimEnd('/')
}

function Test-DcWindowsPath([string]$Path) { $Path -match '^[A-Za-z]:([\\/]|$)' }

# projects.json "path": the folder of a project that lives outside projectsRoot - a Linux path, or a
# Windows path for a project kept on the Windows drive. '' = the usual <projectsRoot>/<name>.
function Get-DcProjectPath([string]$Project, $Config = $null) {
    if ($null -eq $Config) { $Config = Get-DcProjectConfig }
    $e = $Config[$Project]
    if ($e -and $e.PSObject.Properties['path'] -and $e.path) { return ([string]$e.path).Trim() }
    ''
}

# The project folder as a Linux path (what bash scripts cd into).
function Get-DcProjectDir([string]$Project) {
    Assert-DcProjectName $Project
    $p = Get-DcProjectPath $Project
    if ($p) { return ConvertTo-DcLinuxPath $p }
    "$(Get-DcProjectsRoot)/$Project"
}

# Runs docker compose in a project (or its composeDir). $Services limits up/restart to those services.
# Refuses up/restart when the compose project name already has containers from ANOTHER folder
# (e.g. a git worktree whose compose name clashes with the main checkout's) - that would replace them.
function Invoke-DcCompose([string]$Project, [ValidateSet('up', 'down', 'restart')][string]$Action, [string]$SubDir = '', [string[]]$Services = @()) {
    Assert-DcProjectName $Project
    if ($SubDir -match '(^|/)\.\.(/|$)') { throw "Invalid composeDir '$SubDir'" }
    $svc = (@($Services | Where-Object { $_ } | ForEach-Object { ConvertTo-DcBashLiteral $_ }) -join ' ')
    $cmd = @{ up = "docker compose up -d $svc"; down = 'docker compose down'; restart = "docker compose restart $svc" }[$Action]
    $path = (Get-DcProjectDir $Project) + $(if ($SubDir) { "/$($SubDir.Trim('/'))" } else { '' })
    $script = @'
cd __DIR__ || exit 3
if [ "__ACTION__" != down ]; then
  name=$(docker compose config 2>/dev/null | awk '/^name:/{print $2; exit}')
  other=$(docker ps -a --filter "label=com.docker.compose.project=$name" --format '{{.Label "com.docker.compose.project.working_dir"}}' | sort -u | grep -vxF "$PWD" | head -1)
  if [ -n "$other" ]; then
    echo "REFUSED: compose project '$name' already has containers from $other - running it here would replace them."
    exit 4
  fi
fi
__CMD__ 2>&1
'@
    $script = $script.Replace('__DIR__', (ConvertTo-DcBashLiteral $path)).Replace('__ACTION__', $Action).Replace('__CMD__', $cmd)
    $timeout = if ($Action -eq 'up') { 1800 } else { 300 }
    $r = Invoke-DcLinux $script $timeout
    $tail = (@($r.Out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '\.profile: line' }) | Select-Object -Last 15) -join "`n"
    if ($r.ExitCode -ne 0) { throw "compose $Action failed for '$Project' (exit $($r.ExitCode)):`n$tail$($r.Err)" }
    Write-DcLog "compose $Action $Project ok"
    $tail
}

function Get-DcCodePath {
    $s = Get-DcSettings
    if ($s.codePath -and (Test-Path $s.codePath)) { return $s.codePath }
    $c = Get-Command 'code.cmd' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd")) {
        if (Test-Path $p) { return $p }
    }
    throw 'VS Code (code.cmd) not found - set codePath in settings.json'
}

# Note: this boots WSL if it is stopped (both flavors run in / connect to Linux).
# codeFlavor (settings.json): 'linux' (default) = Linux VS Code under WSLg via
# ~/.local/bin/code-linux (installed by the repo's Linux setup, not by Dev Control), which carries
# the flags that make it usable under WSLg (Wayland, no GPU); 'windows' = Windows VS Code
# --remote wsl+<distro>.
function Get-DcCodeFlavor {
    $s = Get-DcSettings
    if ($s.codeFlavor -eq 'windows') { 'windows' } else { 'linux' }
}

# The editor a project opens in by default: its projects.json codeFlavor, else 'windows' for a
# project on a Windows path (that is where it is used), else the codeFlavor setting.
function Get-DcProjectFlavor([string]$Project) {
    $e = (Get-DcProjectConfig)[$Project]
    if ($e -and $e.PSObject.Properties['codeFlavor'] -and $e.codeFlavor -in @('linux', 'windows')) { return [string]$e.codeFlavor }
    if (Test-DcWindowsPath (Get-DcProjectPath $Project)) { return 'windows' }
    Get-DcCodeFlavor
}

# An empty $Project opens a new window with no folder loaded ("-n"), from $HOME.
# $Flavor 'linux' / 'windows' picks the editor for this call (the Linux / Windows buttons); empty =
# the project's default (Get-DcProjectFlavor). Windows VS Code with no project opens a plain LOCAL
# window (no WSL needed); with a project it opens the Linux folder through Remote - WSL, or a project on
# a Windows path locally.
# -Restore (Linux, no project): plain `code-linux`, which reopens the last session's windows when VS Code
# is not running; without it an empty window opens (-n).
function Open-DcVSCode([string]$Project, [string]$Flavor, [switch]$Restore) {
    $s = Get-DcSettings
    $path = ''
    $winPath = ''
    if ($Project) {
        $path = Get-DcProjectDir $Project
        $pp = Get-DcProjectPath $Project
        if (Test-DcWindowsPath $pp) { $winPath = $pp }
    }
    if ($Flavor -notin @('linux', 'windows')) { $Flavor = if ($Project) { Get-DcProjectFlavor $Project } else { Get-DcCodeFlavor } }
    $linux = $Flavor -eq 'linux'
    $label = if ($linux) { 'Linux' } else { 'Windows' }
    if ($linux) {
        # exit 127 = launcher missing (reported below instead of a silent failure)
        $launch = "[ -x `"`$HOME/.local/bin/code-linux`" ] || exit 127`n"
        $script = if ($path) { $launch + "cd $(ConvertTo-DcBashLiteral $path) && exec `"`$HOME/.local/bin/code-linux`" ." }
                  elseif ($Restore) { $launch + "cd `"`$HOME`" && exec `"`$HOME/.local/bin/code-linux`"" }
                  else { $launch + "cd `"`$HOME`" && exec `"`$HOME/.local/bin/code-linux`" -n" }
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
        Write-DcCallLog 'CODE' ("linux " + $(if ($path) { $path } else { '-n (no folder)' }))
        $p = Start-DcDetached 'wsl.exe' "-d $($s.distro) -- bash -lc `"echo $b64 | base64 -d | bash`""
    } elseif ($winPath) {
        $code = Get-DcCodePath
        $path = $winPath
        Write-DcCallLog 'CODE' "windows (local) `"$winPath`""
        $p = Start-DcDetached 'cmd.exe' "/d /c `"`"$code`" `"$winPath`"`""
    } elseif ($path) {
        $code = Get-DcCodePath
        Write-DcCallLog 'CODE' "windows --remote wsl+$($s.distro) `"$path`""
        $p = Start-DcDetached 'cmd.exe' "/d /c `"`"$code`" --remote wsl+$($s.distro) `"$path`"`""
    } else {
        $code = Get-DcCodePath
        Write-DcCallLog 'CODE' 'windows -n (local, no folder)'
        $p = Start-DcDetached 'cmd.exe' "/d /c `"`"$code`" -n`""
    }
    if ($p.WaitForExit(20000) -and $p.ExitCode -ne 0) {
        if ($linux -and $p.ExitCode -eq 127) { throw '~/.local/bin/code-linux was not found in WSL - install it (the repo''s Linux setup does), or use the Windows VS Code button' }
        throw "code exited with $($p.ExitCode)"
    }
    if ($path) { "Opened $path in VS Code ($label)." }
    elseif ($Restore -and $linux) { "Reopened Linux VS Code with its previous windows." }
    else { "Opened an empty VS Code window ($label)." }
}

# Fix Linux windows (FIX-022): Linux windows that vanished (minimized or off-screen when WSLg reconnected)
# or click in the wrong place (stale monitor layout). The WSLg Helper's -Repair does the Win32 work:
# restore minimized, move off-screen ones, restart msrdc. Returns its messages and how many Linux VS Code
# windows are on screen afterwards (-1 = unknown).
function Repair-DcLinuxWindows {
    $helper = Join-Path $env:LOCALAPPDATA 'Programs\WslgHelper\wslg-helper.ps1'
    if (-not (Test-Path $helper)) {
        Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-DcLog 'Fix Linux windows: WSLg Helper not installed - restarted msrdc only.'
        return [pscustomobject]@{ Lines = @('Reconnected WSLg (msrdc). Install the WSLg Helper for the full repair.'); CodeWindows = -1 }
    }
    $r = Invoke-DcProcess 'powershell.exe' "-NoProfile -STA -ExecutionPolicy Bypass -File `"$helper`" -Repair" 90
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() })
    $cw = -1
    foreach ($l in $lines) { if ($l -match '^CODEWINDOWS (-?\d+)') { $cw = [int]$Matches[1] } }
    $msgs = @($lines | Where-Object { $_ -notmatch '^CODEWINDOWS ' })
    Write-DcLog ("Fix Linux windows: " + ($msgs -join ' ') + " Linux VS Code windows on screen: $cw")
    [pscustomobject]@{ Lines = $msgs; CodeWindows = $cw }
}

# Fix WSL (FIX-030): WSL 2.7 leaks the Linux end of some wsl.exe calls ("Relay" processes); with dozens,
# new wsl.exe calls slow down and hang, and so do screenshot paste and explorer.exe / clip.exe from Linux.
# The WSLg Helper ends them every 5 min; its -Reap does it now. Returns its messages and how many it
# ended (-1 = WSL did not answer).
function Repair-DcWslRelays {
    $helper = Join-Path $env:LOCALAPPDATA 'Programs\WslgHelper\wslg-helper.ps1'
    if (-not (Test-Path $helper)) { throw 'the WSLg Helper is not installed (install.ps1 step 3) - it does the cleanup' }
    $r = Invoke-DcProcess 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$helper`" -Reap" 120
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_.Trim() })
    $n = -1
    foreach ($l in $lines) { if ($l -match '^RELAYS (-?\d+)') { $n = [int]$Matches[1] } }
    $msgs = @($lines | Where-Object { $_ -notmatch '^RELAYS ' })
    Write-DcLog ("Fix WSL: " + ($msgs -join ' '))
    [pscustomobject]@{ Lines = $msgs; Ended = $n }
}

# A Linux VS Code window WSLg dropped cannot be brought back from either side; a clean quit and a plain
# start (hot exit) reopens every window with its editors.
function Restart-DcVSCode {
    $a = Stop-DcVSCode
    Start-Sleep -Seconds 2
    $b = Open-DcVSCode '' 'linux' -Restore
    "$a $b"
}

# Linux VS Code processes all report comm 'code'; the ROOTS (parent is not itself a code
# process) are one per running application instance - what SIGTERM has to reach.
# The Windows flavor's remote server is node, not code, so this never matches it.
# Starts with a blank line: it is appended to scripts that do not end in a newline.
$script:DcCodeRoots = @'

codepids=$(ps -eo pid=,comm= | awk '$2 == "code" { print $1 }' | tr '\n' ' ')
roots=
for p in $codepids; do
  pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  case " $codepids " in *" $pp "*) ;; *) roots="$roots $p" ;; esac
done
roots=$(echo $roots)
'@

# Quits the Linux VS Code running under WSLg: SIGTERM to each instance (hot exit restores
# unsaved editors), SIGKILL to whatever is still alive 20s later.
function Stop-DcVSCode {
    $script = $script:DcCodeRoots + @'

[ -z "$roots" ] && { echo "VS Code is not running in WSL."; exit 0; }
n=$(echo $roots | wc -w)
kill -TERM $roots 2>/dev/null
left="$roots"
for i in $(seq 1 40); do
  alive=
  for p in $left; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
  left=$(echo $alive)
  [ -z "$left" ] && break
  sleep 0.5
done
if [ -n "$left" ]; then
  kill -KILL $left 2>/dev/null
  echo "Quit VS Code ($n instance(s); $(echo $left | wc -w) needed SIGKILL)."
else
  echo "Quit VS Code ($n instance(s))."
fi
'@
    $r = Invoke-DcLinux $script 60
    if ($r.ExitCode -ne 0) { throw "Quitting VS Code failed: $($r.Err)" }
    $out = @($r.Out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '\.profile: line' })
    Write-DcLog ($out -join ' ')
    ($out | Select-Object -Last 1)
}

# ---------------------------------------------------------------- containers

# Background tools: started detached (own session) with a pid file holding "pid boot_id",
# so a pid left over from before a WSL restart is never mistaken for a live process.
$script:DcToolPrelude = @'
run="$HOME/.cache/devcontrol/run"
bootid=$(cat /proc/sys/kernel/random/boot_id)
alive() { local p b; read -r p b < "$1" 2>/dev/null || return 1; [ "$b" = "$bootid" ] && kill -0 "$p" 2>/dev/null; }
'@

function Get-DcSlug([string]$Name) { ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }

function Get-DcRuntime {
    $script = $script:DcToolPrelude + @'

docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "com.docker.compose.service"}}' | sed 's/^/C\t/'
docker stats --no-stream --format '{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' | sed 's/^/S\t/'
for pidf in "$run"/*/*.pid; do
  [ -f "$pidf" ] || continue
  slug=$(basename "$(dirname "$pidf")"); n=$(basename "$pidf" .pid); read -r p b < "$pidf"
  if alive "$pidf"; then
    u=$(ps -o pcpu=,rss= --sid "$p" | awk '{c+=$1; r+=$2} END {printf "%.1f\t%d", c, r*1024}')
    printf 'T\t%s\t%s\t%s\t1\t%s\n' "$slug" "$n" "$p" "$u"
  else
    printf 'T\t%s\t%s\t%s\t0\t\t\n' "$slug" "$n" "$p"
  fi
done
'@ + $script:DcCodeRoots + @'

printf 'V\t%s\n' "$(echo $roots | wc -w)"
'@ + "`nif $($script:DcNetTest); then printf 'N\t1\n'; else printf 'N\t0\n'; fi`n"
    $r = Invoke-DcLinux $script 60
    if ($r.ExitCode -ne 0) { throw "docker ps/stats failed: $($r.Err)" }
    $lines = @($r.Out -split "`r?`n")
    $stats = @{}
    foreach ($l in ($lines | Where-Object { $_.StartsWith("S`t") })) { $f = $l.Split("`t"); $stats[$f[1]] = $f }
    $containers = @($lines | Where-Object { $_.StartsWith("C`t") } | ForEach-Object {
        $f = $_.Split("`t")
        $st = $stats[$f[1]]
        [pscustomobject]@{
            Id      = $f[1]
            Name    = $f[2]
            Image   = $f[3]
            Status  = $f[4]
            Dir     = if ($f.Count -gt 5) { $f[5] } else { '' }
            Service = if ($f.Count -gt 6) { $f[6] } else { '' }
            Cpu     = if ($st) { $st[2] } else { '-' }
            Mem     = if ($st) { ($st[3] -split '/')[0].Trim() } else { '-' }
            MemPerc = if ($st) { $st[4] } else { '-' }
        }
    })
    $tools = @($lines | Where-Object { $_.StartsWith("T`t") } | ForEach-Object {
        $f = $_.Split("`t")
        [pscustomobject]@{
            Slug    = $f[1]
            Tool    = $f[2]
            Pid     = $f[3]
            Running = $f[4] -eq '1'
            Cpu     = if ($f[4] -eq '1') { "$($f[5])%" } else { '-' }
            Mem     = if ($f[4] -eq '1') { Format-DcBytes ([int64]$f[6]) } else { '-' }
        }
    })
    $vs = @($lines | Where-Object { $_.StartsWith("V`t") } | ForEach-Object { [int]($_.Split("`t")[1]) })
    $net = @($lines | Where-Object { $_.StartsWith("N`t") } | ForEach-Object { $_.Split("`t")[1] -eq '1' })
    [pscustomobject]@{ Containers = $containers; Tools = $tools; VSCode = $(if ($vs.Count) { $vs[0] } else { 0 })
        Network = $(if ($net.Count) { $net[0] } else { $true }) }
}

# One-shot tools run to completion in the project folder; background tools are detached.
function Get-DcToolDir([string]$Project, $Tool) {
    $cwd = if ($Tool.PSObject.Properties['cwd'] -and $Tool.cwd) { [string]$Tool.cwd } else { '' }
    if ($cwd -match '(^|/)\.\.(/|$)') { throw "Invalid tool cwd '$cwd'" }
    ConvertTo-DcBashLiteral ((Get-DcProjectDir $Project) + $(if ($cwd) { "/$($cwd.Trim('/'))" } else { '' }))
}

function Invoke-DcTool([string]$Project, $Tool) {
    $dir = Get-DcToolDir $Project $Tool
    $cmd = ConvertTo-DcBashLiteral ([string]$Tool.command)
    if (-not $Tool.command) { throw "Tool '$($Tool.name)' in $Project has no command" }
    if ($Tool.background) {
        $script = $script:DcToolPrelude + @'

state="$run/__SLUG__"; mkdir -p "$state"
pidf="$state/__TOOL__.pid"; logf="$state/__TOOL__.log"
if alive "$pidf"; then read -r p b < "$pidf"; echo "already running (pid $p)"; exit 0; fi
cd __DIR__ || exit 3
setsid nohup bash -lc __CMD__ >"$logf" 2>&1 </dev/null &
echo "$! $bootid" > "$pidf"
sleep 1
if alive "$pidf"; then echo "started (pid $!, log $logf)"; else echo "exited immediately, last output:"; tail -5 "$logf"; exit 1; fi
'@
        $script = $script.Replace('__SLUG__', (Get-DcSlug $Project)).Replace('__TOOL__', (Get-DcSlug $Tool.name)).Replace('__DIR__', $dir).Replace('__CMD__', $cmd)
        $r = Invoke-DcLinux $script 60
    } else {
        $timeout = if ($Tool.timeoutSeconds) { [int]$Tool.timeoutSeconds } else { 600 }
        $r = Invoke-DcLinux "cd $dir || exit 3`nbash -lc $cmd 2>&1" $timeout
    }
    $tail = (@($r.Out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '\.profile: line' }) | Select-Object -Last 8) -join "`n"
    if ($r.ExitCode -ne 0) { throw "tool '$($Tool.name)' failed in '$Project' (exit $($r.ExitCode)):`n$tail" }
    Write-DcLog "tool $($Tool.name) $Project ok"
    $tail
}

# A tool's optional "stop" command (e.g. systemctl --user stop ...), run by the project's Stop.
function Invoke-DcToolStop([string]$Project, $Tool) {
    $dir = Get-DcToolDir $Project $Tool
    $r = Invoke-DcLinux "cd $dir || exit 3`nbash -lc $(ConvertTo-DcBashLiteral ([string]$Tool.stop)) 2>&1" 120
    $tail = (@($r.Out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '\.profile: line' }) | Select-Object -Last 5) -join ' / '
    if ($r.ExitCode -ne 0) { throw "stop for tool '$($Tool.name)' failed (exit $($r.ExitCode)): $tail" }
    "stop '$($Tool.name)': ok $tail".Trim()
}

# Stops a project's background tools (TERM to the whole session, KILL after 10s).
# $ToolSlug limits it to one tool.
function Stop-DcTools([string]$ProjectSlug, [string]$ToolSlug = '') {
    if ($ProjectSlug -notmatch '^[a-z0-9-]+$' -or ($ToolSlug -and $ToolSlug -notmatch '^[a-z0-9-]+$')) { throw "Invalid tool id '$ProjectSlug/$ToolSlug'" }
    $script = $script:DcToolPrelude + @'

only=__ONLY__
for pidf in "$run/__SLUG__"/*.pid; do
  [ -f "$pidf" ] || continue
  n=$(basename "$pidf" .pid)
  [ -n "$only" ] && [ "$n" != "$only" ] && continue
  if alive "$pidf"; then
    read -r p b < "$pidf"
    kill -TERM -- -"$p" 2>/dev/null || kill -TERM "$p"
    for i in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$p" 2>/dev/null && kill -KILL -- -"$p" 2>/dev/null
    echo "stopped $n"
  fi
  rm -f "$pidf"
done
true
'@
    $script = $script.Replace('__SLUG__', $ProjectSlug).Replace('__ONLY__', $(if ($ToolSlug) { $ToolSlug } else { "''" }))
    $r = Invoke-DcLinux $script 60
    if ($r.ExitCode -ne 0) { throw "Stopping tools failed: $($r.Err)" }
    $out = @($r.Out -split "`r?`n" | Where-Object { $_ -like 'stopped *' })
    if ($out) { $out -join ', ' } else { 'no tools running' }
}

function Stop-DcContainer([string]$Id) {
    if ($Id -notmatch '^[0-9a-f]{6,64}$') { throw "Invalid container id '$Id'" }
    $r = Invoke-DcLinux "docker stop $Id" 120
    if ($r.ExitCode -ne 0) { throw "docker stop $Id failed: $($r.Err)" }
    "Stopped $Id."
}

function Stop-DcAllContainers {
    $r = Invoke-DcLinux 'ids=$(docker ps -q); if [ -z "$ids" ]; then echo 0; else docker stop $ids >/dev/null && echo $ids | wc -w; fi' 300
    if ($r.ExitCode -ne 0) { throw "Stopping containers failed: $($r.Err)" }
    $n = (@($r.Out -split "`r?`n" | Where-Object { $_ -match '^\d+$' }) | Select-Object -Last 1)
    "Stopped $n container(s)."
}

# ---------------------------------------------------------------- project config

# projects.json: { "groups": [...], "collapsed": [...],
#                 "projects": { "<folder name>": { displayName, description, path, codeFlavor, group, mode, pinned, hidden, url, warning,
#                                                  compose, composeDir, services, openVSCode, tools[] } } }
function Get-DcConfigPath {
    if ($env:DEVCONTROL_PROJECTS_JSON) { return $env:DEVCONTROL_PROJECTS_JSON }   # self-test uses a copy
    Join-Path $script:DcAppDir 'projects.json'
}

function Get-DcConfigFile {
    $path = Get-DcConfigPath
    if (-not (Test-Path $path)) { return [pscustomobject]@{ projects = [pscustomobject]@{} } }
    Get-Content -Raw -Encoding UTF8 -Path $path | ConvertFrom-Json
}

# Readable JSON (2-space indent, short objects/arrays on one line). ConvertTo-Json in PS 5.1
# pads with odd spacing and escapes apostrophes, which hurts a file people edit by hand.
function ConvertTo-DcJson($Value, [int]$Indent = 0) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return $Value.ToString($inv) }
    if ($Value -is [string]) {
        $sb = New-Object System.Text.StringBuilder '"'
        foreach ($ch in $Value.ToCharArray()) {
            switch ($ch) {
                '"'  { [void]$sb.Append('\"') }
                '\'  { [void]$sb.Append('\\') }
                "`n" { [void]$sb.Append('\n') }
                "`r" { [void]$sb.Append('\r') }
                "`t" { [void]$sb.Append('\t') }
                default { if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) } else { [void]$sb.Append($ch) } }
            }
        }
        return $sb.Append('"').ToString()
    }
    $pad = '  ' * $Indent; $pad1 = '  ' * ($Indent + 1)
    if ($Value -is [System.Collections.IDictionary]) { $pairs = @($Value.Keys | ForEach-Object { , @([string]$_, $Value[$_]) }) }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) { $pairs = @($Value.PSObject.Properties | ForEach-Object { , @($_.Name, $_.Value) }) }
    elseif ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-DcJson $_ ($Indent + 1) })
        if ($items.Count -eq 0) { return '[]' }
        $inline = '[' + ($items -join ', ') + ']'
        if ($inline.Length -le 100 -and $inline -notmatch "`n") { return $inline }
        return "[`n$pad1" + ($items -join ",`n$pad1") + "`n$pad]"
    }
    else { return (ConvertTo-DcJson ([string]$Value) $Indent) }
    if ($pairs.Count -eq 0) { return '{}' }
    $parts = @($pairs | ForEach-Object { (ConvertTo-DcJson $_[0]) + ': ' + (ConvertTo-DcJson $_[1] ($Indent + 1)) })
    $inline = '{ ' + ($parts -join ', ') + ' }'
    if ($Indent -gt 1 -and $inline.Length -le 110 -and $inline -notmatch "`n") { return $inline }
    "{`n$pad1" + ($parts -join ",`n$pad1") + "`n$pad}"
}

# Writes projects.json atomically, keeping the previous version as projects.json.bak in the data dir.
function Save-DcConfigFile($Config) {
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Get-DcConfigPath))
    $text = (ConvertTo-DcJson $Config) + "`n"
    [void]($text | ConvertFrom-Json)   # never write something we cannot read back
    # a redirected config (self-test) keeps its backup next to it, so the real .bak is never replaced
    $bak = if ($env:DEVCONTROL_PROJECTS_JSON) { "$path.bak" } else { Join-Path $script:DcDataDir 'projects.json.bak' }
    if (Test-Path $path) { Copy-Item -Force $path $bak }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $tmp $path
}

function Get-DcProjectConfig {
    $j = Get-DcConfigFile
    $cfg = @{}
    if ($j.PSObject.Properties['projects'] -and $j.projects) { foreach ($p in $j.projects.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    $cfg
}

function Format-DcBytes([int64]$b) {
    if ($b -le 0) { return '-' }
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    '{0:N0} MB' -f ($b / 1MB)
}

# ---------------------------------------------------------------- cleaner: stale dev servers, leftover browsers and tabs
# Cleaner.cs (started by the UI) records, without starting any process, which listening sockets had connections and
# from which local program (cleaner-net.json), and the automation Chrome's tabs with who last changed each one
# (cleaner-tabs.json). Invoke-DcCleanup reads them every cleanerCheckMinutes; after cleanerIdleHours it
#  - stops a dev server (a cleanerServerPrograms process listening on a port, with the shell or program tree that
#    started it) when it had no connection that long OR the Claude session that started it has been idle or gone that
#    long - never while the user's own browser used it in that time or a tab the user navigated is on it;
#  - stops a Playwright browser whose script is gone (pipe-driven, no parent: nothing can drive it any more);
#  - closes a tab of the automation Chrome that automation left and nobody changed since (a tab the user navigated
#    is the user's and is never closed), always leaving one tab open;
#  - warns once per Windows start when the kernel pools pass kernelPoolWarnGB (a leaking driver): one warning,
#    then quiet.
# Stopping uses Stop-Process, closing a tab the DevTools HTTP endpoint; no process is started.

$script:DcCleanerShells   = @('bash', 'sh', 'cmd', 'powershell', 'pwsh')
$script:DcCleanerHosts    = @('explorer') + $script:DcCleanerShells   # an interactive shell or Explorer started it: the user
$script:DcCleanerBrowsers = @('chrome', 'msedge', 'firefox', 'brave', 'chromium', 'chrome-headless-shell', 'headless_shell')

function Initialize-DcCleanerTypes {
    if (-not ('DevControl.Cleaner.Watch' -as [type])) {
        Add-Type -Path (Join-Path $script:DcAppDir 'Cleaner.cs') -ReferencedAssemblies 'System.Web.Extensions'
    }
}

function ConvertFrom-DcIso($Value) {
    if ($null -eq $Value -or '' -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Read-DcDataJson([string]$Name) {
    $path = Join-Path $script:DcDataDir $Name
    for ($i = 0; $i -lt 3; $i++) {
        try { if (Test-Path $path) { return (Get-Content -Raw -Path $path -Encoding UTF8 | ConvertFrom-Json) } else { return $null } }
        catch { Start-Sleep -Milliseconds 200 }
    }
    $null
}

function Format-DcAge([TimeSpan]$Span) {
    if ($Span.TotalHours -ge 1) { '{0:N1} h' -f $Span.TotalHours } else { '{0:N0} min' -f $Span.TotalMinutes }
}

function Get-DcShort([string]$Text, [int]$Max) { if ($Text.Length -le $Max) { $Text } else { $Text.Substring(0, $Max - 3) + '...' } }

# pid -> { Id, Parent, Name (lower case, no .exe), Cmd, Path, Start }
function Get-DcProcSnapshot {
    $byId = @{}
    foreach ($p in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate, ExecutablePath -ErrorAction Stop)) {
        $byId[[int]$p.ProcessId] = [pscustomobject]@{
            Id = [int]$p.ProcessId; Parent = [int]$p.ParentProcessId
            Name = [IO.Path]::GetFileNameWithoutExtension([string]$p.Name).ToLowerInvariant()
            Cmd = [string]$p.CommandLine; Path = [string]$p.ExecutablePath; Start = $p.CreationDate
        }
    }
    $byId
}

# The parent, if it still runs (a reused pid started after its "child" is not the parent).
function Get-DcLiveParent($Procs, $P) {
    $q = $Procs[$P.Parent]
    if ($q -and $q.Id -ne $P.Id -and $q.Start -and $P.Start -and $q.Start -le $P.Start.AddSeconds(2)) { return $q }
    $null
}

function Get-DcProcChildren($Procs) {
    $kids = @{}
    foreach ($p in $Procs.Values) {
        $par = Get-DcLiveParent $Procs $p
        if ($par) {
            if (-not $kids.ContainsKey($par.Id)) { $kids[$par.Id] = New-Object System.Collections.ArrayList }
            [void]$kids[$par.Id].Add($p)
        }
    }
    $kids
}

# Root first, then its descendants (stopping the parent first keeps it from restarting a child, e.g. wrangler's workerd).
function Get-DcProcTree($Kids, $Root) {
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count) {
        $p = $queue.Dequeue()
        if ($seen.ContainsKey($p.Id)) { continue }
        $seen[$p.Id] = $true; [void]$out.Add($p)
        if ($Kids.ContainsKey($p.Id)) { foreach ($k in $Kids[$p.Id]) { $queue.Enqueue($k) } }
    }
    , $out.ToArray()
}

function Stop-DcProcTree($Tree) {
    $n = 0
    foreach ($p in $Tree) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $n++ } catch { } }
    $n
}

# A shell running a command or a script (bash -c / bash <file>, cmd /c, powershell -Command / -File / x.ps1), not
# one the user types into (no arguments, bash --login -i, cmd /k, pwsh -NoLogo).
function Test-DcScriptShell($P) {
    if ($script:DcCleanerShells -notcontains $P.Name) { return $false }
    $rest = $P.Cmd.Trim()
    if ($rest.StartsWith('"')) { $i = $rest.IndexOf('"', 1); $rest = if ($i -gt 0) { $rest.Substring($i + 1) } else { '' } }
    else { $i = $rest.IndexOf(' '); $rest = if ($i -gt 0) { $rest.Substring($i) } else { '' } }
    $rest = $rest.Trim()
    if (-not $rest) { return $false }
    if ($P.Name -eq 'cmd') { return [bool]($rest -match '(?i)(^|\s)/c(\s|$)') }
    if ($P.Name -eq 'bash' -or $P.Name -eq 'sh') {
        return [bool](($rest -match '(^|\s)-[a-zA-Z]*c[a-zA-Z]*(\s|$)') -or @($rest -split '\s+' | Where-Object { $_ -and -not $_.StartsWith('-') }).Count)
    }
    [bool](($rest -match '(?i)(^|\s)-(c|command|f|file|e|ec|encodedcommand|noninteractive)(\s|$)') -or ($rest -match '(?i)\.ps1'))
}

# Text of what starts at Windows sign-in (Startup folders, Run keys), lower case with / for \. A server whose script
# appears in it (a local tool started from the Startup folder) is a service the user relies on, never a stale dev server.
function Get-DcAutostartText {
    $parts = New-Object System.Collections.ArrayList
    foreach ($d in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        if (-not $d -or -not (Test-Path $d)) { continue }
        foreach ($f in @(Get-ChildItem -Path $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(vbs|cmd|bat|ps1|js)$' })) {
            try { [void]$parts.Add((Get-Content -Raw -Path $f.FullName)) } catch { }
        }
    }
    foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
        try { $v = Get-ItemProperty -Path $k -ErrorAction Stop; foreach ($p in $v.PSObject.Properties) { if ($p.Name -notlike 'PS*') { [void]$parts.Add([string]$p.Value) } } } catch { }
    }
    (($parts -join "`n").ToLowerInvariant()).Replace('\', '/')
}

# The script a node/python/... process runs (tools\server.mjs), lower case with /, or ''.
function Get-DcScriptArg($P) {
    if ($P.Cmd -match '(?i)\s"?([^\s"]+\.(mjs|cjs|js|ts|py))"?(\s|$)') { return $Matches[1].ToLowerInvariant().Replace('\', '/') }
    ''
}

# Live Claude Code sessions (~/.claude/sessions/<pid>.json) by pid: Name, Busy, Since (last status change, UTC).
function Get-DcClaudeSessions($Procs) {
    $out = @{}
    $dir = Join-Path $env:USERPROFILE '.claude\sessions'
    foreach ($f in @(Get-ChildItem -Path $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json } catch { continue }
        if (-not $j.pid) { continue }
        $p = $Procs[[int]$j.pid]
        if (-not $p) { continue }
        if ($j.procStart -and $p.Start) {
            $started = [DateTime]::FromFileTime([int64]$j.procStart)
            if ([Math]::Abs(($started - $p.Start).TotalSeconds) -gt 5) { continue }   # the pid belongs to another process now
        }
        $ms = [Math]::Max([double]$j.updatedAt, [double]$j.statusUpdatedAt)
        $out[[int]$j.pid] = [pscustomobject]@{
            Pid = [int]$j.pid; Name = [string]$j.name; Busy = ([string]$j.status -eq 'busy')
            Since = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).UtcDateTime
        }
    }
    $out
}

# Walks up from a listening process through dev programs and script shells to the tree to stop (Root) and who
# started it: Kind 'session' (a Claude session's Bash/PowerShell tool), 'orphan' (its starter is gone), 'user' (an
# interactive shell or Explorer), or one never touched: 'session-direct' (started by the session itself, e.g. an MCP
# server), 'session-self', 'app' (any other program, e.g. Adobe's node).
function Get-DcProcOwner($Procs, $Sessions, $P, [string[]]$Programs) {
    $cur = $P
    $seen = @{}
    while (-not $seen.ContainsKey($cur.Id)) {
        $seen[$cur.Id] = $true
        if ($Sessions.ContainsKey($cur.Id)) { return [pscustomobject]@{ Root = $null; Kind = 'session-self'; Session = $null; Via = '' } }
        $par = Get-DcLiveParent $Procs $cur
        if (-not $par) { return [pscustomobject]@{ Root = $cur; Kind = 'orphan'; Session = $null; Via = '' } }
        if ($Sessions.ContainsKey($par.Id)) {
            $kind = if ($script:DcCleanerShells -contains $cur.Name) { 'session' } else { 'session-direct' }
            return [pscustomobject]@{ Root = $cur; Kind = $kind; Session = $Sessions[$par.Id]; Via = $par.Name }
        }
        if ($Programs -contains $par.Name -or (Test-DcScriptShell $par)) { $cur = $par; continue }
        $kind = if ($script:DcCleanerHosts -contains $par.Name) { 'user' } else { 'app' }
        return [pscustomobject]@{ Root = $cur; Kind = $kind; Session = $null; Via = $par.Name }
    }
    [pscustomobject]@{ Root = $null; Kind = 'loop'; Session = $null; Via = '' }
}

function Test-DcAutomationBrowser($P) {
    ($P.Cmd -match '(?i)--remote-debugging-(port|pipe)|-juggler|--headless|playwright') -or ($P.Path -match '(?i)\\ms-playwright\\')
}

# A dev server's client counts as the user's own browser when it still runs, is a browser and its main process
# was not started for automation (DevTools port or pipe, headless, Playwright's build or profile).
function Test-DcUserBrowser($Procs, [int]$ClientPid, [string]$Name) {
    $p = $Procs[$ClientPid]
    if (-not $p -or $script:DcCleanerBrowsers -notcontains $p.Name -or ($Name -and $Name.ToLowerInvariant() -ne $p.Name)) { return $false }
    for ($i = 0; $i -lt 8; $i++) { $par = Get-DcLiveParent $Procs $p; if ($par -and $par.Name -eq $p.Name) { $p = $par } else { break } }
    -not (Test-DcAutomationBrowser $p)
}

function Get-DcOrphanAge($Orphans, $Seen, $P, [DateTime]$Now) {
    $key = '{0}@{1}' -f $P.Id, $P.Start.ToUniversalTime().Ticks
    $Seen[$key] = $true
    if (-not $Orphans.ContainsKey($key) -or -not $Orphans[$key]) { $Orphans[$key] = $Now }
    $Now - $Orphans[$key]
}

# One pass. -DryRun (or cleanerDryRun) only reports; -IdleHours overrides cleanerIdleHours; -Explain also lists
# what was kept and why. Test hooks (tests/Test-Cleaner.ps1): -OnlyPorts limits dev servers to those ports and
# -OnlyPids limits browsers to those pids (either one set = everything else is left alone). Returns
# { Actions, Kept, Warn, DryRun }.
function Invoke-DcCleanup([switch]$DryRun, [double]$IdleHours = -1, [switch]$Explain, [int[]]$OnlyPorts = @(), [int[]]$OnlyPids = @()) {
    $limited = ($OnlyPorts.Count + $OnlyPids.Count) -gt 0
    Initialize-DcCleanerTypes
    $s = Get-DcSettings
    if ($IdleHours -lt 0) { $IdleHours = [double]$s.cleanerIdleHours }
    $dry = $DryRun -or [bool]$s.cleanerDryRun
    $stopV = if ($dry) { 'Would stop' } else { 'Stopped' }
    $closeV = if ($dry) { 'Would close' } else { 'Closed' }
    $now = [DateTime]::UtcNow
    $acts = New-Object System.Collections.ArrayList
    $kept = New-Object System.Collections.ArrayList

    $state = Read-DcDataJson 'cleaner-state.json'
    $orphans = @{}
    if ($state -and $state.orphans) { foreach ($o in $state.orphans.PSObject.Properties) { $orphans[$o.Name] = ConvertFrom-DcIso $o.Value } }
    $warnedBoot = if ($state) { [string]$state.poolWarnedBoot } else { '' }
    $seenOrphans = @{}
    $warn = $null

    $procs = Get-DcProcSnapshot
    $kids = Get-DcProcChildren $procs
    $sessions = Get-DcClaudeSessions $procs
    $programs = @($s.cleanerServerPrograms | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $keepPorts = @($s.cleanerKeepPorts | ForEach-Object { [int]$_ })
    $autostart = Get-DcAutostartText
    $net = Read-DcDataJson 'cleaner-net.json'
    $tabFile = Read-DcDataJson 'cleaner-tabs.json'
    $tabs = @()
    if ($tabFile -and $tabFile.tabs) {
        $tabs = @($tabFile.tabs.PSObject.Properties | ForEach-Object {
            $t = $_.Value
            [pscustomobject]@{ Id = $_.Name; Url = [string]$t.url; Title = [string]$t.title; Owner = [string]$t.owner; Since = ConvertFrom-DcIso $t.since }
        })
    }

    $listen = @{}   # pid -> listening ports
    foreach ($r in @([DevControl.Cleaner.Net]::Rows())) {
        if ($r.State -ne 2) { continue }
        if (-not $listen.ContainsKey($r.Pid)) { $listen[$r.Pid] = New-Object 'System.Collections.Generic.HashSet[int]' }
        [void]$listen[$r.Pid].Add($r.LocalPort)
    }
    $mainPort = [int]$s.cleanerChromePort

    # ---- leftover automation browsers whose script is gone: Playwright's (pipe or playwright_ profile: nothing can
    # drive them any more) and headless Chromes on their own DevTools port (once nothing connected for the idle time).
    # Never the automation Chrome on cleanerChromePort, never a browser the user started.
    foreach ($p in @($procs.Values)) {
        if ($script:DcCleanerBrowsers -notcontains $p.Name -or $p.Cmd -match '--type=') { continue }
        if ($limited -and $OnlyPids -notcontains $p.Id) { continue }
        $ports = if ($listen.ContainsKey($p.Id)) { @($listen[$p.Id]) } else { @() }
        if ($p.Cmd -match ('--remote-debugging-port={0}(\D|$)' -f $mainPort) -or $ports -contains $mainPort) { continue }
        $pipe = $p.Cmd -match '(?i)--remote-debugging-pipe|-juggler-pipe|playwright_'
        $portDriven = (-not $pipe) -and ($p.Cmd -match '--remote-debugging-port=') -and ($p.Cmd -match '--headless')
        if (-not $pipe -and -not $portDriven) { continue }
        if (Get-DcLiveParent $procs $p) { continue }
        $age = Get-DcOrphanAge $orphans $seenOrphans $p $now
        $label = '{0} browser pid {1}' -f $p.Name, $p.Id
        if ($age.TotalHours -lt $IdleHours) {
            if ($Explain) { [void]$kept.Add(('Keep {0}: its script ended {1} ago' -f $label, (Format-DcAge $age))) }
            continue
        }
        $why = 'its script ended {0} ago' -f (Format-DcAge $age)
        if ($portDriven) {
            # something may still drive it over its port: it needs a watched, quiet port too
            $quietOk = $false
            if ($net -and $net.servers -and $ports.Count) {
                $quietOk = $true
                foreach ($port in $ports) {
                    $e = $net.servers.PSObject.Properties[('{0}:{1}' -f $p.Id, $port)]
                    if (-not $e) { $quietOk = $false; break }
                    $first = ConvertFrom-DcIso $e.Value.firstSeen
                    $t = ConvertFrom-DcIso $e.Value.lastActive
                    if (-not $t) { $t = $first }
                    if ((($now - $first).TotalHours -lt [Math]::Min($IdleHours, 1.0)) -or (($now - $t).TotalHours -lt $IdleHours)) { $quietOk = $false; break }
                }
            }
            if (-not $quietOk) {
                if ($Explain) { [void]$kept.Add(('Keep {0}: its DevTools port {1} was used (or watched) less than {2} h ago' -f $label, ($ports -join ', '), $IdleHours)) }
                continue
            }
            $why += '; nothing connected to its DevTools port for {0} h' -f $IdleHours
        }
        $tree = Get-DcProcTree $kids $p
        $n = if ($dry) { $tree.Count } else { Stop-DcProcTree $tree }
        [void]$acts.Add(('{0} a leftover {1} browser (pid {2}, {3} processes): {4}' -f $stopV, $p.Name, $p.Id, $n, $why))
    }

    # ---- stale dev servers
    $userTabPorts = @{}
    foreach ($t in $tabs) {
        if ($t.Owner -eq 'user' -and $t.Url -match '^https?://(localhost|127\.0\.0\.1|\[::1\]):(\d+)') { $userTabPorts[[int]$Matches[2]] = $true }
    }
    $groups = @{}
    foreach ($lp in @($listen.Keys)) {
        $p = $procs[[int]$lp]
        if (-not $p -or $programs -notcontains $p.Name) { continue }
        $ports = @($listen[$lp])
        if (@($ports | Where-Object { $keepPorts -contains $_ }).Count) { continue }
        if ($limited -and -not @($ports | Where-Object { $OnlyPorts -contains $_ }).Count) { continue }
        $own = Get-DcProcOwner $procs $sessions $p $programs
        if (@('session', 'orphan', 'user') -notcontains $own.Kind) {
            if ($Explain) { [void]$kept.Add(('Keep {0} pid {1} on port {2}: started by {3} ({4})' -f $p.Name, $p.Id, ($ports -join ', '), $own.Via, $own.Kind)) }
            continue
        }
        $rid = $own.Root.Id
        if (-not $groups.ContainsKey($rid)) {
            $groups[$rid] = [pscustomobject]@{ Owner = $own; Keys = New-Object System.Collections.ArrayList; Ports = New-Object System.Collections.ArrayList }
        }
        foreach ($port in $ports) { [void]$groups[$rid].Keys.Add(('{0}:{1}' -f $lp, $port)); [void]$groups[$rid].Ports.Add($port) }
    }
    foreach ($g in $groups.Values) {
        $root = $g.Owner.Root
        $portText = (@($g.Ports | Sort-Object -Unique) -join ', ')
        $label = '{0} pid {1} on port {2}' -f $root.Name, $root.Id, $portText
        $tree = Get-DcProcTree $kids $root
        $boot = @($tree | ForEach-Object { Get-DcScriptArg $_ } | Where-Object { $_ -and $autostart.Contains($_) })
        if ($boot.Count) {
            if ($Explain) { [void]$kept.Add(('Keep {0}: starts at Windows sign-in ({1})' -f $label, $boot[0])) }
            continue
        }
        $age = $now - $root.Start.ToUniversalTime()
        if ($age.TotalHours -lt $IdleHours) {
            if ($Explain) { [void]$kept.Add(('Keep {0}: started {1} ago' -f $label, (Format-DcAge $age))) }
            continue
        }
        $known = $false; $last = $null; $userUse = $false; $userTab = $false; $watched = $null
        if ($net -and $net.servers) {
            foreach ($key in $g.Keys) {
                $e = $net.servers.PSObject.Properties[$key]
                if (-not $e) { continue }
                $known = $true; $e = $e.Value
                $first = ConvertFrom-DcIso $e.firstSeen
                if ($first -and (-not $watched -or $first -lt $watched)) { $watched = $first }
                $t = ConvertFrom-DcIso $e.lastActive
                if (-not $t) { $t = $first }
                if (-not $last -or $t -gt $last) { $last = $t }
                if ($e.clients) {
                    foreach ($c in $e.clients.PSObject.Properties) {
                        $seenAt = ConvertFrom-DcIso $c.Value.lastSeen
                        if ($seenAt -and ($now - $seenAt).TotalHours -lt $IdleHours -and (Test-DcUserBrowser $procs ([int]$c.Name) ([string]$c.Value.name))) { $userUse = $true }
                    }
                }
            }
        }
        foreach ($port in $g.Ports) { if ($userTabPorts.ContainsKey([int]$port)) { $userTab = $true } }
        if (-not $known) {
            if ($Explain) { [void]$kept.Add(('Keep {0}: no connection record yet (the watcher runs in Dev Control); started by {1}' -f $label, $g.Owner.Kind)) }
            continue
        }
        # Who used it is only known for the time the watcher has seen it (Dev Control restarted): watch a while first.
        $need = [Math]::Min($IdleHours, 1.0)
        if (($now - $watched).TotalHours -lt $need) {
            if ($Explain) { [void]$kept.Add(('Keep {0}: watched for {1} so far, {2} h needed' -f $label, (Format-DcAge ($now - $watched)), $need)) }
            continue
        }
        if ($userUse -or $userTab) {
            $reason = if ($userTab) { 'a tab you navigated is on it' } else { 'your browser used it in the last {0} h' -f $IdleHours }
            if ($Explain) { [void]$kept.Add(('Keep {0}: {1}' -f $label, $reason)) }
            continue
        }
        $why = @()
        $quiet = $now - $last
        if ($quiet.TotalHours -ge $IdleHours) { $why += ('no connection for {0}' -f (Format-DcAge $quiet)) }
        # An orphan (its shell ended, e.g. a server backgrounded with &) may still serve a running session: only its
        # own connections decide. A session's server also goes when that session has been idle that long.
        if ($g.Owner.Kind -eq 'session') {
            $ss = $g.Owner.Session
            if (-not $ss.Busy -and ($now - $ss.Since).TotalHours -ge $IdleHours) { $why += ('its Claude session "{0}" idle for {1}' -f $ss.Name, (Format-DcAge ($now - $ss.Since))) }
        }
        if (-not $why.Count) {
            if ($Explain) { [void]$kept.Add(('Keep {0}: last connection {1} ago, started by {2}' -f $label, (Format-DcAge $quiet), $(if ($g.Owner.Session) { 'session "' + $g.Owner.Session.Name + '"' } else { $g.Owner.Kind }))) }
            continue
        }
        $n = if ($dry) { $tree.Count } else { Stop-DcProcTree $tree }
        [void]$acts.Add(('{0} the dev server on port {1} ({2} pid {3}, {4} process{5}): {6}' -f $stopV, $portText, $root.Name, $root.Id, $n, $(if ($n -eq 1) { '' } else { 'es' }), ($why -join '; ')))
    }

    # ---- leftover tabs in the automation Chrome
    if ($tabs.Count) {
        $keepTabs = @($s.cleanerKeepTabs | ForEach-Object { [string]$_ })
        $cands = @($tabs | Where-Object {
            $u = $_.Url
            (@('auto', 'unknown') -contains $_.Owner) -and $_.Since -and (($now - $_.Since).TotalHours -ge $IdleHours) -and
            ($u -notmatch '^(devtools|chrome-extension)://') -and -not @($keepTabs | Where-Object { $u -like $_ }).Count
        })
        if ($cands.Count -and $cands.Count -ge $tabs.Count) { $cands = @($cands | Sort-Object Since | Select-Object -SkipLast 1) }
        if ($Explain) {
            foreach ($t in $tabs) {
                if (@($cands | Where-Object { $_.Id -eq $t.Id }).Count) { continue }
                [void]$kept.Add(('Keep tab "{0}" ({1}): {2}, unchanged for {3}' -f (Get-DcShort $t.Title 50), (Get-DcShort $t.Url 70), $t.Owner, $(if ($t.Since) { Format-DcAge ($now - $t.Since) } else { '?' })))
            }
        }
        $watching = ('DevControl.Cleaner.Watch' -as [type]) -and ([DevControl.Cleaner.Watch]::TabStatus -like 'following*')
        if ($cands.Count -and ($watching -or $dry)) {
            $wc = New-Object Net.WebClient
            $wc.Proxy = $null
            $base = 'http://127.0.0.1:{0}/json' -f [int]$s.cleanerChromePort
            $live = @{}
            try { $list = $wc.DownloadString("$base/list") | ConvertFrom-Json; foreach ($t in $list) { $live[[string]$t.id] = [string]$t.url } } catch { $live = $null }
            if ($live) {
                foreach ($t in $cands) {
                    if (-not $live.ContainsKey($t.Id) -or $live[$t.Id] -ne $t.Url) { continue }   # closed or changed since the watcher wrote
                    if (-not $dry) { try { [void]$wc.DownloadString("$base/close/$($t.Id)") } catch { continue } }
                    [void]$acts.Add(('{0} the tab "{1}" ({2}): automation left it {3} ago' -f $closeV, (Get-DcShort $t.Title 60), (Get-DcShort $t.Url 80), (Format-DcAge ($now - $t.Since))))
                }
            }
        }
    }

    # ---- kernel memory: one warning per Windows start
    $gb = [double]$s.kernelPoolWarnGB
    if ($gb -gt 0) {
        $bytes = [DevControl.Cleaner.Mem]::KernelPoolBytes()
        $boot = (Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime).LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm')
        if ($bytes -ge $gb * 1GB -and $warnedBoot -ne $boot) {
            $warn = 'Windows kernel memory is at {0:N1} GB (normal is about 1.5 GB): a driver is leaking again, and a restart clears it. This shows once until the next restart.' -f ($bytes / 1GB)
            if (-not $dry) { $warnedBoot = $boot }
        }
    }

    $keepOrphans = [ordered]@{}
    foreach ($k in $seenOrphans.Keys) { $keepOrphans[$k] = $orphans[$k].ToString('o') }
    $out = [ordered]@{ updated = $now.ToString('o'); poolWarnedBoot = $warnedBoot; orphans = $keepOrphans }
    try { [IO.File]::WriteAllText((Join-Path $script:DcDataDir 'cleaner-state.json'), ($out | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false)) } catch { }
    foreach ($a in $acts) { Write-DcFile 'cleaner.log' ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $a) }
    [pscustomobject]@{ Actions = $acts.ToArray(); Kept = $kept.ToArray(); Warn = $warn; DryRun = $dry }
}
