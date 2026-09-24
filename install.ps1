<#
.SYNOPSIS
  WSL-Windows-KD-Custom-Setup installer: Linux VS Code under WSLg as your everyday editor, with the
  fixes that make it behave like a Windows app. Asks before each part; safe to run again.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes -Distro Ubuntu
#>
param(
    [string]$Distro,        # WSL distro to set up (default: your default distro)
    [switch]$Yes,           # accept the default answer to every question
    [string]$ProjectsRoot,  # Dev Control projects folder inside Linux (default: ~/Documents)
    [switch]$VerifyOnly     # change nothing; just check that every fix is in effect
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
. (Join-Path $Root 'windows\lib\common.ps1')
$script:AssumeYes = [bool]$Yes

Write-Host "$SetupName installer" -ForegroundColor Cyan
Write-Host 'Every change is per-user (no admin). uninstall.ps1 reverses it.'

# ------------------------------------------------------------------ prerequisites
Write-Step 'Checking prerequisites'
if ([Environment]::OSVersion.Version.Build -lt 22000) { throw 'Windows 11 is required (WSLg and conhost --headless).' }
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is not installed. Run: wsl --install -d Ubuntu' }
$distros = Get-WslDistros
if (-not $distros) { throw 'No WSL distro found. Run: wsl --install -d Ubuntu   (then open it once to create your user)' }
if (-not $Distro) {
    $def = ($distros | Where-Object Default | Select-Object -First 1).Name
    if (-not $def) { $def = $distros[0].Name }
    $Distro = Read-Value "WSL distro to use ($(($distros.Name) -join ', '))" $def
}
if ($distros.Name -notcontains $Distro) { throw "Distro '$Distro' not found. Installed: $(($distros.Name) -join ', ')" }
if (($distros | Where-Object Name -eq $Distro).Version -eq 1) { throw "'$Distro' is WSL 1; WSLg needs WSL 2 (wsl --set-version $Distro 2)." }
Write-Ok "Distro: $Distro (starting it if needed)"
$linuxUser = Get-LinuxUser $Distro
$linuxHome = Get-LinuxHome $Distro
if (-not $linuxHome -or $linuxUser -eq 'root') { throw "Could not find a normal Linux user in '$Distro' (got '$linuxUser'). Open the distro once to create one." }
Write-Ok "Linux user: $linuxUser ($linuxHome)"
if (-not (Test-Path "\\wsl.localhost\$Distro\mnt\wslg")) { Write-Warn2 'WSLg not detected (\\wsl.localhost\<distro>\mnt\wslg missing). Update WSL: wsl --update' }
if ($VerifyOnly) {
    Write-Step 'Verifying fixes'
    exit (Test-Setup $Distro)
}
$linuxDir = ConvertTo-LinuxPath $Distro (Join-Path $Root 'linux')
$codeExe = Get-WindowsCodeExe
$state = @{ distro = $Distro; linuxHome = $linuxHome; installed = @(); date = (Get-Date).ToString('s') }

# ------------------------------------------------------------------ 1. Linux side
Write-Step '1. Linux VS Code and launchers (inside Linux)'
Write-Note 'Installs Linux VS Code (Microsoft apt repo) if missing, clipboard/voice/font packages, and the'
Write-Note 'code-linux launchers in ~/.local/bin (Wayland + no-GPU flags that fix the offset mouse pointer).'
if (Read-YesNo 'Set up the Linux side?') {
    Write-Note 'Installing packages as root (apt; this can take a few minutes the first time)...'
    & wsl.exe -d $Distro -u root --exec sh "$linuxDir/setup-linux.sh" packages
    if ($LASTEXITCODE -ne 0) { throw 'Linux package setup failed (see output above).' }
    & wsl.exe -d $Distro --exec sh "$linuxDir/setup-linux.sh" user
    if ($LASTEXITCODE -ne 0) { throw 'Linux user setup failed (see output above).' }
    $state.installed += 'linux'
    Write-Ok 'Linux side done.'
}

# ------------------------------------------------------------------ 2. Windows launchers
Write-Step '2. Windows launchers'
Write-Note 'Start Menu: "VS Code (Linux)" and "VS Code (Windows)"; Explorer right-click "Open in VS Code (Linux)";'
Write-Note 'optional desktop shortcut. Windows VS Code stays installed and untouched.'
if (Read-YesNo 'Create the launchers?') {
    $openLinux = "$linuxHome/.local/bin/code-linux-open"
    # wsl.exe through a headless console: no console window flashes up. (wslg.exe is not used: on some
    # machines it exits -1 without running anything.)
    $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
    $args0 = "--headless wsl.exe -d $Distro -e $openLinux"
    $icon = if ($codeExe) { "$codeExe,0" } else { (Join-Path $env:WINDIR 'System32\wsl.exe') + ',0' }

    New-Shortcut (Join-Path $StartMenu 'VS Code (Linux).lnk') $conhost $args0 $icon 'Linux VS Code (WSLg) - reopens your last workspace'
    Write-Ok 'Start Menu: VS Code (Linux)'
    if ($codeExe) {
        New-Shortcut (Join-Path $StartMenu 'VS Code (Windows).lnk') $codeExe '' "$codeExe,0" 'Windows VS Code' (Split-Path $codeExe)
        Write-Ok 'Start Menu: VS Code (Windows)'
    } else { Write-Note 'Windows VS Code not found - skipped "VS Code (Windows)".' }
    if (Read-YesNo 'Also put "VS Code (Linux)" on the desktop?') {
        New-Shortcut (Join-Path $Desktop 'VS Code (Linux).lnk') $conhost $args0 $icon 'Linux VS Code (WSLg) - reopens your last workspace'
        Write-Ok 'Desktop: VS Code (Linux)'
        $state.desktopShortcut = $true
    }
    foreach ($base in 'Directory\shell', 'Directory\Background\shell') {
        $key = "HKCU:\Software\Classes\$base\$RightClickKey"
        New-Item -Force -Path "$key\command" | Out-Null
        Set-ItemProperty -Path $key -Name '(default)' -Value 'Open in VS Code (Linux)'
        Set-ItemProperty -Path $key -Name 'Icon' -Value $(if ($codeExe) { "`"$codeExe`"" } else { (Join-Path $env:WINDIR 'System32\wsl.exe') })
        Set-ItemProperty -Path "$key\command" -Name '(default)' -Value "`"$conhost`" $args0 `"%V`""
    }
    Write-Ok 'Explorer right-click: Open in VS Code (Linux)  (Windows 11: under "Show more options")'
    $state.installed += 'launchers'
}

# ------------------------------------------------------------------ 3. WSLg Helper
Write-Step '3. WSLg Helper (background task)'
Write-Note 'Fixes two WSLg problems: after sleep/screen-off Linux windows click in the wrong place and snap'
Write-Note 'badly (stale monitor layout), and screenshots cannot be pasted into Linux apps (image format).'
if (Read-YesNo 'Install the WSLg Helper?') {
    # Screenshot paste hands images to Linux with wl-copy; install it even if step 1 was skipped.
    Invoke-Wsl $Distro @('sh', '-c', 'command -v wl-copy') | Out-Null
    if ($script:WslExit -ne 0) {
        Write-Note 'Installing wl-clipboard in the distro (needed for screenshot paste)...'
        & wsl.exe -d $Distro -u root --exec sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q wl-clipboard || (apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q wl-clipboard)'
    }
    Stop-ScheduledTask -TaskName $HelperTask -ErrorAction SilentlyContinue
    Stop-ScriptProcess 'wslg-helper.ps1'
    New-Item -ItemType Directory -Force $HelperDir | Out-Null
    Copy-Item (Join-Path $Root 'windows\wslg-helper\wslg-helper.ps1') $HelperDir -Force
    (@{ distro = $Distro } | ConvertTo-Json) | Set-Content (Join-Path $HelperDir 'helper-config.json') -Encoding ASCII
    $script = Join-Path $HelperDir 'wslg-helper.ps1'
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\conhost.exe') `
        -Argument "--headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File `"$script`""
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $HelperTask -Force `
        -Description "WSLg fixes: monitor layout resync after sleep, clipboard images as PNG for Linux apps. ($SetupName)" `
        -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $me) -Settings $settings `
        -Principal (New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited) | Out-Null
    Start-ScheduledTask -TaskName $HelperTask
    Write-Ok "Installed to $HelperDir; runs at logon (task '$HelperTask'), started now."
    $state.installed += 'helper'
}

# ------------------------------------------------------------------ 4. Drag-to-snap
Write-Step '4. Drag-to-snap for Linux windows'
Write-Note 'Lets Windows handle title-bar drags of Linux windows, so dragging to a screen edge snaps them.'
Write-Note 'Sets WESTON_RDPRAIL_SHELL_LOCAL_MOVE=true in %USERPROFILE%\.wslgconfig (takes effect after WSL restarts).'
if (Read-YesNo 'Enable drag-to-snap?') {
    $cfg = Join-Path $env:USERPROFILE '.wslgconfig'
    $line = 'WESTON_RDPRAIL_SHELL_LOCAL_MOVE=true'
    $lines = if (Test-Path $cfg) { @(Get-Content $cfg) } else { @() }
    if ($lines -match '^\s*WESTON_RDPRAIL_SHELL_LOCAL_MOVE\s*=') {
        $lines = $lines -replace '^\s*WESTON_RDPRAIL_SHELL_LOCAL_MOVE\s*=.*$', $line
    } elseif ($lines -match '^\s*\[system-distro-env\]') {
        $out = @(); foreach ($l in $lines) { $out += $l; if ($l -match '^\s*\[system-distro-env\]') { $out += $line } }; $lines = $out
    } else {
        $lines += @('[system-distro-env]', "; Drag-to-snap for Linux windows ($SetupName)", $line)
    }
    Set-Content -Path $cfg -Value $lines -Encoding ASCII
    Write-Ok "$cfg updated."
    $state.installed += 'snap'
    $state.needsWslRestart = $true
}

# ------------------------------------------------------------------ 5. Dev Control
Write-Step '5. Dev Control (optional app)'
Write-Note 'A Windows app to start/stop WSL, switch .wslconfig modes, run Docker Compose projects and open'
Write-Note 'them in Linux VS Code. Installs to %LOCALAPPDATA%\Programs\DevControl with Start Menu + desktop shortcuts.'
if (Read-YesNo 'Install Dev Control?') {
    if (-not $ProjectsRoot) { $ProjectsRoot = Read-Value 'Folder inside Linux that holds your projects' "$linuxHome/Documents" }
    Write-Note 'The launcher exe is built on this machine. Signing it with a local self-signed certificate (trusted'
    Write-Note 'for your Windows user only) stops SmartScreen from warning about it. Windows asks you to confirm.'
    $sign = Read-YesNo 'Sign Dev Control with a local certificate?' $true
    $deploy = @{ Distro = $Distro; ProjectsRoot = $ProjectsRoot; Build = $true }
    if ($sign) { $deploy.Sign = $true }
    & (Join-Path $Root 'devcontrol\Deploy.ps1') @deploy
    $state.installed += 'devcontrol'
    $state.devcontrolSigned = $sign
}

Save-SetupState $state

# ------------------------------------------------------------------ finish
Write-Step 'Verifying fixes'
$missing = Test-Setup $Distro
Write-Step 'Done'
Write-Note "Installed: $((@($state.installed)) -join ', ')"
if ($missing) { Write-Warn2 "$missing fix(es) not in effect - see MISSING above." }
if ($state.needsWslRestart) {
    Write-Warn2 'Drag-to-snap starts working after WSL restarts. Restarting closes every Linux app (save your work).'
    if (Read-YesNo 'Restart WSL now?' $false) { & wsl.exe --shutdown; Write-Ok 'WSL stopped; it starts again with the next Linux app.' }
    else { Write-Note 'Later: run  wsl --shutdown  (or reboot).' }
}
Write-Note 'Open Linux VS Code from Start: "VS Code (Linux)". Logs and troubleshooting: docs\troubleshooting.md'
