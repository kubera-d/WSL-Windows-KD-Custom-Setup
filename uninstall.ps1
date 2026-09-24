<#
.SYNOPSIS
  Reverses install.ps1. Asks before each part. Windows VS Code, Linux VS Code and apt packages are
  left installed; only what this project added is removed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
param(
    [string]$Distro,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
. (Join-Path $Root 'windows\lib\common.ps1')
$script:AssumeYes = [bool]$Yes

$state = Get-SetupState
if (-not $Distro -and $state) { $Distro = $state.distro }
if (-not $Distro) { $Distro = (Get-WslDistros | Where-Object Default | Select-Object -First 1).Name }
Write-Host "$SetupName uninstaller (distro: $Distro)" -ForegroundColor Cyan

Write-Step 'WSLg Helper'
if ((Get-ScheduledTask -TaskName $HelperTask -ErrorAction SilentlyContinue) -or (Test-Path $HelperDir)) {
    if (Read-YesNo 'Remove the WSLg Helper task and files?') {
        Stop-ScheduledTask -TaskName $HelperTask -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $HelperTask -Confirm:$false -ErrorAction SilentlyContinue
        Stop-ScriptProcess 'wslg-helper.ps1'
        Remove-Item $HelperDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'Removed.'
    }
} else { Write-Note 'Not installed.' }

Write-Step 'Windows launchers'
$lnks = @((Join-Path $StartMenu 'VS Code (Linux).lnk'), (Join-Path $StartMenu 'VS Code (Windows).lnk'), (Join-Path $Desktop 'VS Code (Linux).lnk')) | Where-Object { Test-Path $_ }
$keys = @('Directory\shell', 'Directory\Background\shell') | ForEach-Object { "HKCU:\Software\Classes\$_\$RightClickKey" } |
    Where-Object { (Test-Path "$_\command") -and ((Get-ItemProperty "$_\command").'(default)' -like '*code-linux-open*') }
if ($lnks -or $keys) {
    if (Read-YesNo 'Remove the VS Code (Linux)/(Windows) shortcuts and the right-click entry?') {
        $lnks | ForEach-Object { Remove-Item $_ -Force; Write-Ok "Removed $_" }
        $keys | ForEach-Object { Remove-Item $_ -Recurse -Force; Write-Ok "Removed $_" }
    }
} else { Write-Note 'Not installed.' }

Write-Step 'Drag-to-snap (.wslgconfig)'
$cfg = Join-Path $env:USERPROFILE '.wslgconfig'
if ((Test-Path $cfg) -and (Select-String -Path $cfg -Pattern '^\s*WESTON_RDPRAIL_SHELL_LOCAL_MOVE\s*=' -Quiet)) {
    if (Read-YesNo 'Turn drag-to-snap off again?') {
        $lines = @(Get-Content $cfg | Where-Object { $_ -notmatch '^\s*WESTON_RDPRAIL_SHELL_LOCAL_MOVE\s*=' -and $_ -notmatch [regex]::Escape("($SetupName)") })
        $meaningful = @($lines | Where-Object { $_ -notmatch '^\s*($|;|#|\[system-distro-env\])' })
        if ($meaningful.Count -eq 0) { Remove-Item $cfg -Force; Write-Ok "Removed $cfg" }
        else { Set-Content -Path $cfg -Value $lines -Encoding ASCII; Write-Ok "Removed the setting from $cfg" }
        Write-Note 'Takes effect after WSL restarts (wsl --shutdown).'
    }
} else { Write-Note 'Not set.' }

Write-Step 'Dev Control'
$dcUninstall = Join-Path $Root 'devcontrol\Uninstall-DevControl.ps1'
if (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\DevControl')) {
    if (Read-YesNo 'Uninstall Dev Control? (your settings.json / projects.json are backed up first)') {
        $rmCert = $false
        if ($state -and $state.devcontrolSigned) { $rmCert = Read-YesNo 'Also remove its local signing certificate?' $true }
        if ($rmCert) { & $dcUninstall -RemoveCertificate } else { & $dcUninstall }
    }
} else { Write-Note 'Not installed.' }

Write-Step 'Linux side'
if ($Distro -and (Read-YesNo "Remove the code-linux launchers and desktop entries from '$Distro'?")) {
    $linuxDir = ConvertTo-LinuxPath $Distro (Join-Path $Root 'linux')
    & wsl.exe -d $Distro --exec sh "$linuxDir/setup-linux.sh" uninstall-user
}

if (Test-Path $StateFile) { Remove-Item $StateDir -Recurse -Force }
Write-Step 'Done'
Write-Note 'Left installed: Windows VS Code, Linux VS Code, apt packages (wl-clipboard, sox, fonts...), ~/.vscode/argv.json.'
