<#
.SYNOPSIS
  Removes Dev Control: shortcuts and the install folder (after backing up your settings).

.DESCRIPTION
  1. Closes a running Dev Control from that folder.
  2. Copies settings.json / projects.json to %LOCALAPPDATA%\DevControl\uninstall-backup-<date>\.
  3. Removes the "Dev Control" Start Menu / Desktop shortcuts that point into the install folder.
  4. Removes the install folder.
  -RemoveCertificate also removes the 'CN=KD Dev Tools' certificate from CurrentUser My / Root /
  TrustedPublisher (Windows asks to confirm the Root removal).
  -RemoveData also removes the logs and caches in %LOCALAPPDATA%\DevControl (backups are kept).
  Never touches WSL: ~/.cache/devcontrol inside Linux and your .wslconfig stay as they are.
  Runs in Windows PowerShell 5.1. Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\DevControl'),
    [switch]$RemoveCertificate,
    [switch]$RemoveData
)
$ErrorActionPreference = 'Stop'
$dataDir = Join-Path $env:LOCALAPPDATA 'DevControl'
$signSubject = 'CN=KD Dev Tools'
function Write-Step([string]$Text) { Write-Host "uninstall: $Text" }

$installed = Test-Path (Join-Path $Destination 'DevControl.ps1')
if ((Test-Path $Destination) -and -not $installed) {
    throw "$Destination does not look like a Dev Control install (no DevControl.ps1) - not removing it."
}

if ($installed) {
    # 1. close a running instance (it holds the icon files open)
    $script = (Join-Path $Destination 'DevControl.ps1').ToLowerInvariant()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($script) })
    foreach ($p in $procs) {
        Write-Step "closing Dev Control (pid $($p.ProcessId))"
        $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($gp) {
            if ($gp.MainWindowHandle -ne [IntPtr]::Zero) { [void]$gp.CloseMainWindow() }
            if (-not $gp.WaitForExit(5000)) { Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    # 2. back up the user-edited files
    $backup = Join-Path $dataDir ("uninstall-backup-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
    foreach ($f in 'settings.json', 'projects.json') {
        $p = Join-Path $Destination $f
        if (Test-Path $p) {
            New-Item -ItemType Directory -Force -Path $backup | Out-Null
            Copy-Item -Force $p $backup
        }
    }
    if (Test-Path $backup) { Write-Step "backed up settings.json / projects.json to $backup" }
}

# 3. shortcuts (only ours: target inside the install folder)
$shell = New-Object -ComObject WScript.Shell
$prefix = ([IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\').ToLowerInvariant()
foreach ($folder in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop')) {
    $lnk = Join-Path $folder 'Dev Control.lnk'
    if (-not (Test-Path $lnk)) { continue }
    $target = [string]$shell.CreateShortcut($lnk).TargetPath
    if ($target.ToLowerInvariant().StartsWith($prefix)) { Remove-Item -Force $lnk; Write-Step "removed $lnk" }
    else { Write-Step "kept $lnk (points to $target, not to $Destination)" }
}

# 4. install folder
if ($installed) {
    Remove-Item -Recurse -Force $Destination
    Write-Step "removed $Destination"
} else {
    Write-Step "nothing installed at $Destination"
}

if ($RemoveCertificate) {
    foreach ($store in 'My', 'Root', 'TrustedPublisher') {
        foreach ($c in @(Get-ChildItem "Cert:\CurrentUser\$store" -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $signSubject })) {
            Remove-Item -Path "Cert:\CurrentUser\$store\$($c.Thumbprint)"
            Write-Step "removed certificate $($c.Thumbprint) from CurrentUser\$store"
        }
    }
}

if ($RemoveData) {
    if (Test-Path $dataDir) {
        Get-ChildItem -Force $dataDir | Where-Object { $_.Name -notlike 'uninstall-backup-*' } | Remove-Item -Recurse -Force
        Write-Step "removed logs and caches in $dataDir (uninstall backups kept)"
    }
} else {
    Write-Step "kept logs in $dataDir (use -RemoveData to remove them)"
}
Write-Step 'done.'
