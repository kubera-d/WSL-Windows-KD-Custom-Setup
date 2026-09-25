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
        containerRefreshSeconds = 10
        projectRefreshSeconds   = 30
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

function Get-DcStatus {
    $running = Test-DcWslRunning
    $mode = Get-DcCurrentMode
    [pscustomobject]@{
        Running        = $running
        MemoryBytes    = if ($running) { Get-DcWslMemory } else { [int64]0 }
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

function Stop-DcWsl {
    Write-DcCallLog 'SHUT' '--shutdown'
    $r = Invoke-DcProcess 'wsl.exe' '--shutdown' 90
    if ($r.ExitCode -ne 0) { throw "wsl --shutdown failed ($($r.ExitCode)): $($r.Err)$($r.Out)" }
    if (-not (Wait-DcWslState $false 30)) { throw 'WSL still reports running 30s after --shutdown' }
    Write-DcLog 'WSL shut down'
    'WSL shut down.'
}

# The ONLY function that boots WSL on purpose.
function Start-DcWslBoot {
    $s = Get-DcSettings
    $msgs = @()
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
    # Wait for dockerd (systemd starts it a moment after boot).
    $r = Invoke-DcLinux 'for i in $(seq 1 60); do docker info >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1' 90
    $msgs += if ($r.ExitCode -eq 0) { 'Docker is ready.' } else { 'WARNING: Docker did not respond within 60s.' }
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
# Exception: entries with a "path" are listed from that folder (outside projectsRoot, Windows paths via /mnt).
# Reports the compose file (in the folder, or in its configured composeDir), git-worktree details
# and last activity so the UI can classify them.
function Get-DcProjects {
    $root = Get-DcProjectsRoot
    $cfg = Get-DcProjectConfig
    $cfgLines = @($cfg.Keys | ForEach-Object {
        $sub = if ($cfg[$_].PSObject.Properties['composeDir']) { [string]$cfg[$_].composeDir } else { '' }
        $pp = Get-DcProjectPath $_ $cfg
        # 0x1f, not tab: read collapses runs of IFS whitespace, so an empty composeDir would eat the path
        $_ + [char]0x1f + $sub + [char]0x1f + $(if ($pp) { ConvertTo-DcLinuxPath $pp })
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
    @($lines | Where-Object { $_.StartsWith("P`t") } | ForEach-Object {
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
    } | Sort-Object Name)
}

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
function Open-DcVSCode([string]$Project, [string]$Flavor) {
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
    if ($path) { "Opened $path in VS Code ($label)." } else { "Opened an empty VS Code window ($label)." }
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
'@
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
    [pscustomobject]@{ Containers = $containers; Tools = $tools; VSCode = $(if ($vs.Count) { $vs[0] } else { 0 }) }
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
