# common.ps1 - helpers shared by install.ps1 and uninstall.ps1. Windows PowerShell 5.1, ASCII only.

$script:SetupName    = 'WSL-Windows-KD-Custom-Setup'
$script:StateDir     = Join-Path $env:LOCALAPPDATA "Programs\$script:SetupName"
$script:StateFile    = Join-Path $script:StateDir 'state.json'
$script:HelperDir    = Join-Path $env:LOCALAPPDATA 'Programs\WslgHelper'
$script:HelperTask   = 'WSLg Helper'
$script:StartMenu    = [Environment]::GetFolderPath('Programs')
$script:Desktop      = [Environment]::GetFolderPath('Desktop')
$script:RightClickKey = 'VSCodeWSL'   # HKCU\Software\Classes\Directory[\Background]\shell\<key>

function Write-Step([string]$Text)  { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)    { Write-Host "   $Text" -ForegroundColor Green }
function Write-Note([string]$Text)  { Write-Host "   $Text" }
function Write-Warn2([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }

# Ask a yes/no question. -Yes on the command line (script:AssumeYes) takes the default.
function Read-YesNo([string]$Question, [bool]$Default = $true) {
    if ($script:AssumeYes) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host "$Question $hint"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        switch -Regex ($a.Trim()) { '^(y|yes)$' { return $true } '^(n|no)$' { return $false } }
    }
}

function Read-Value([string]$Question, [string]$Default) {
    if ($script:AssumeYes) { return $Default }
    $a = Read-Host "$Question [$Default]"
    if ([string]::IsNullOrWhiteSpace($a)) { $Default } else { $a.Trim() }
}

# Registered distros and the default one, from the registry (does not start WSL).
function Get-WslDistros {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return @() }
    $def = (Get-ItemProperty $lxss -ErrorAction SilentlyContinue).DefaultDistribution
    @(Get-ChildItem $lxss | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        [pscustomobject]@{ Name = $p.DistributionName; Default = ($_.PSChildName -eq $def); Version = $p.Version }
    } | Where-Object { $_.Name })
}

# Run a command inside the distro and return trimmed stdout. Starts WSL if it is stopped.
function Invoke-Wsl([string]$Distro, [string[]]$Arguments, [switch]$AsRoot) {
    $a = @('-d', $Distro)
    if ($AsRoot) { $a += @('-u', 'root') }
    $a += @('--exec') + $Arguments
    $out = & wsl.exe @a
    $script:WslExit = $LASTEXITCODE
    ($out | Out-String).Trim()
}

# (No double quotes in arguments: Windows PowerShell 5.1 mangles them when calling native programs.)
function Get-LinuxHome([string]$Distro) { Invoke-Wsl $Distro @('sh', '-c', 'echo $HOME') }
function Get-LinuxUser([string]$Distro) { Invoke-Wsl $Distro @('id', '-un') }
function ConvertTo-LinuxPath([string]$Distro, [string]$WindowsPath) { Invoke-Wsl $Distro @('wslpath', '-u', $WindowsPath) }

function Get-WindowsCodeExe {
    foreach ($p in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe", "$env:ProgramFiles\Microsoft VS Code\Code.exe")) {
        if (Test-Path $p) { return $p }
    }
    $null
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments = '', [string]$Icon = '', [string]$Description = '', [string]$WorkDir = '') {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    if ($Icon) { $lnk.IconLocation = $Icon }
    if ($Description) { $lnk.Description = $Description }
    if ($WorkDir) { $lnk.WorkingDirectory = $WorkDir }
    $lnk.Save()
}

function Get-ShortcutArguments([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    (New-Object -ComObject WScript.Shell).CreateShortcut($Path).Arguments
}

function Save-SetupState([hashtable]$State) {
    New-Item -ItemType Directory -Force $script:StateDir | Out-Null
    ($State | ConvertTo-Json) | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Get-SetupState {
    if (Test-Path $script:StateFile) { try { return Get-Content $script:StateFile -Raw | ConvertFrom-Json } catch {} }
    $null
}

# Checks that every fix is actually in effect. Prints OK / PENDING / MISSING per fix; returns the
# number of MISSING items. PENDING = configured but waiting for something (e.g. a WSL restart).
function Test-Setup([string]$Distro) {
    $rows = New-Object System.Collections.ArrayList
    function Add-Row([string]$Fix, [string]$State, [string]$Detail) { [void]$rows.Add([pscustomobject]@{ Fix = $Fix; State = $State; Detail = $Detail }) }

    $linuxHome = Get-LinuxHome $Distro
    Invoke-Wsl $Distro @('grep', '-q', 'ozone-platform=wayland', "$linuxHome/.local/bin/code-linux") | Out-Null
    if ($script:WslExit -eq 0) { Add-Row 'Mouse offset / glitches (code-linux flags)' 'OK' '~/.local/bin/code-linux' }
    else { Add-Row 'Mouse offset / glitches (code-linux flags)' 'MISSING' 'rerun step 1' }

    $pk = Invoke-Wsl $Distro @('sh', '-c', 'for p in code wl-clipboard xclip sox libsox-fmt-pulse pulseaudio-utils fonts-noto-color-emoji fonts-noto-core xdg-utils; do dpkg -s $p >/dev/null 2>&1 || echo $p; done')
    if (-not $pk) { Add-Row 'Linux packages (VS Code, clipboard, voice, fonts, xdg)' 'OK' 'all installed' }
    else { Add-Row 'Linux packages (VS Code, clipboard, voice, fonts, xdg)' 'MISSING' (($pk -split "\s+") -join ' ') }

    $lnk = Join-Path $script:StartMenu 'VS Code (Linux).lnk'
    $rk = "HKCU:\Software\Classes\Directory\shell\$script:RightClickKey\command"
    if ((Test-Path $lnk) -and (Test-Path $rk)) { Add-Row 'Launchers (Start Menu, right-click)' 'OK' 'VS Code (Linux) / Open in VS Code (Linux)' }
    else { Add-Row 'Launchers (Start Menu, right-click)' 'MISSING' 'rerun step 2' }

    $task = Get-ScheduledTask -TaskName $script:HelperTask -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { Add-Row 'Clicks after sleep (monitor resync)' 'OK' "task '$($script:HelperTask)' running" }
    elseif ($task) { Add-Row 'Clicks after sleep (monitor resync)' 'PENDING' "task is $($task.State); starts at next logon" }
    else { Add-Row 'Clicks after sleep (monitor resync)' 'MISSING' 'rerun step 3' }

    Invoke-Wsl $Distro @('sh', '-c', 'command -v wl-copy') | Out-Null
    if ($task -and $script:WslExit -eq 0) { Add-Row 'Screenshot paste into Linux apps' 'OK' 'helper + wl-copy' }
    else { Add-Row 'Screenshot paste into Linux apps' 'MISSING' $(if (-not $task) { 'rerun step 3' } else { 'wl-clipboard missing in distro' }) }

    $cfg = Join-Path $env:USERPROFILE '.wslgconfig'
    $set = (Test-Path $cfg) -and (Select-String -Path $cfg -Pattern '^\s*WESTON_RDPRAIL_SHELL_LOCAL_MOVE\s*=\s*true' -Quiet)
    $log = "\\wsl.localhost\$Distro\mnt\wslg\weston.log"
    $active = $false
    try { $active = [bool](Select-String -Path $log -Pattern 'local-move:1' -SimpleMatch -Quiet -ErrorAction Stop) } catch {}
    if ($set -and $active) { Add-Row 'Drag-to-snap' 'OK' 'local-move:1' }
    elseif ($set) { Add-Row 'Drag-to-snap' 'PENDING' 'set; active after  wsl --shutdown  (or reboot)' }
    else { Add-Row 'Drag-to-snap' 'MISSING' 'rerun step 4' }

    foreach ($r in $rows) {
        $color = switch ($r.State) { 'OK' { 'Green' } 'PENDING' { 'Yellow' } default { 'Red' } }
        Write-Host ('   {0,-8} {1,-55} {2}' -f $r.State, $r.Fix, $r.Detail) -ForegroundColor $color
    }
    @($rows | Where-Object State -eq 'MISSING').Count
}

# Stop any running copy of a background script by its file name (matched on the command line).
function Stop-ScriptProcess([string]$ScriptName) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$ScriptName*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
