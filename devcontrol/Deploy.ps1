<#
.SYNOPSIS
  Installs or updates Dev Control from this repo into a Windows folder.

.DESCRIPTION
  Copies src\* to -Destination, seeds settings.json / projects.json / modes\*.wslconfig once
  (never overwrites your edits), builds the launcher (icon + DevControl.exe) when needed,
  optionally signs it, and creates the Start Menu (and Desktop) shortcut "Dev Control".
  Runs in Windows PowerShell 5.1. Never starts or stops WSL. Keep this file ASCII-only.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\devcontrol\Deploy.ps1 -ProjectsRoot /home/alice/projects
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\devcontrol\Deploy.ps1 -Build -Sign
#>
[CmdletBinding()]
param(
    # Install folder (the app runs from here).
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\DevControl'),
    # WSL distro name. Default: your default WSL distro (from the registry), else Ubuntu.
    [string]$Distro = '',
    # Linux folder whose subfolders are your projects, e.g. /home/alice/projects.
    [string]$ProjectsRoot = '',
    # Rebuild icon + DevControl.exe (automatic when DevControl.exe is missing).
    [switch]$Build,
    # Create (or reuse) the 'CN=KD Dev Tools' code-signing certificate, trust it for this user, sign the exe.
    [switch]$Sign,
    # Do not create the Desktop shortcut (the Start Menu shortcut is always created).
    [switch]$NoDesktopShortcut
)
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$src  = Join-Path $repo 'src'
$signSubject = 'CN=KD Dev Tools'

function Write-Step([string]$Text) { Write-Host "deploy: $Text" }

# Same rule as Core.ps1: read the default distro from the registry; never ask wsl.exe.
function Get-DefaultDistro {
    try {
        $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        $id = [string](Get-ItemProperty -Path $lxss -Name 'DefaultDistribution' -ErrorAction Stop).DefaultDistribution
        if ($id) {
            $n = [string](Get-ItemProperty -Path "$lxss\$id" -Name 'DistributionName' -ErrorAction Stop).DistributionName
            if ($n) { return $n }
        }
    } catch { }
    'Ubuntu'
}

# JSON string literal, ASCII-only (non-ASCII becomes \uXXXX).
function ConvertTo-JsonLiteral([string]$Value) {
    $sb = New-Object System.Text.StringBuilder '"'
    foreach ($ch in $Value.ToCharArray()) {
        $c = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($c -lt 32 -or $c -gt 126) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    $sb.Append('"').ToString()
}

# Sets "Key": "Value" in a JSON text, keeping the file's layout. Only replaces an EMPTY
# value ("" or null) unless -Force; adds the key after the opening brace when it is missing.
function Set-JsonField([string]$Text, [string]$Key, [string]$Value, [switch]$Force) {
    $lit = ConvertTo-JsonLiteral $Value
    $keyRx = '"' + [regex]::Escape($Key) + '"\s*:\s*'
    $rx = if ($Force) { $keyRx + '("(?:[^"\\]|\\.)*"|null)' } else { $keyRx + '(""|null)' }
    $m = [regex]::Match($Text, $rx)
    if ($m.Success) {
        $prefix = [regex]::Match($m.Value, $keyRx).Value
        return $Text.Substring(0, $m.Index) + $prefix + $lit + $Text.Substring($m.Index + $m.Length)
    }
    if ([regex]::IsMatch($Text, $keyRx)) { return $Text }   # key has a real value: keep it
    $i = $Text.IndexOf('{')
    $Text.Substring(0, $i + 1) + "`r`n  " + (ConvertTo-JsonLiteral $Key) + ': ' + $lit + ',' + $Text.Substring($i + 1)
}

function Write-TextFile([string]$Path, [string]$Text) {
    [void]($Text | ConvertFrom-Json)   # never write something the app cannot read back
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Get-RunningDevControl([string]$Dir) {
    $script = (Join-Path $Dir 'DevControl.ps1').ToLowerInvariant()
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($script) })
}

function New-Shortcut([string]$Path, [string]$Target, [string]$WorkDir, [string]$Icon) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.WorkingDirectory = $WorkDir
    if (Test-Path $Icon) { $lnk.IconLocation = "$Icon,0" }
    $lnk.Description = 'Dev Control - manage WSL2, Docker Compose projects and containers'
    $lnk.Save()
    Write-Step "shortcut $Path"
}

# Creates or reuses the self-signed code-signing certificate and trusts it for THIS user only
# (CurrentUser\Root + CurrentUser\TrustedPublisher - no admin, nothing machine-wide).
# Windows shows a confirmation dialog when a certificate is added to Root: click Yes.
function Initialize-SigningCert {
    $cert = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $signSubject -and $_.NotAfter -gt (Get-Date) } | Sort-Object NotAfter -Descending)[0]
    if ($cert) {
        Write-Step "reusing certificate $signSubject $($cert.Thumbprint) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
    } else {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $signSubject -FriendlyName 'KD Dev Tools code signing' `
            -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(10)
        Write-Step "created certificate $signSubject $($cert.Thumbprint) (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))"
    }
    foreach ($storeName in 'Root', 'TrustedPublisher') {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store $storeName, 'CurrentUser'
        $store.Open('ReadWrite')
        try {
            if (-not $store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false).Count) {
                if ($storeName -eq 'Root') { Write-Step 'adding the certificate to CurrentUser\Root - confirm the Windows security dialog (Yes)' }
                $store.Add($cert)
                Write-Step "trusted in CurrentUser\$storeName"
            }
        } finally { $store.Close() }
    }
}

# ---------------------------------------------------------------- checks

if (-not (Test-Path (Join-Path $src 'DevControl.ps1'))) { throw "src\DevControl.ps1 not found next to Deploy.ps1 ($repo)." }
if ($ProjectsRoot -and -not $ProjectsRoot.StartsWith('/')) { throw "-ProjectsRoot must be a Linux path such as /home/<you>/projects (got '$ProjectsRoot')." }
$ProjectsRoot = $ProjectsRoot.TrimEnd('/')

# Windows PowerShell 5.1 reads BOM-less files as ANSI: every .ps1 / .xaml must be ASCII-only.
$bad = @()
foreach ($f in @(Get-ChildItem -Path $src, $repo, (Join-Path $repo 'tests') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ps1', '.xaml' })) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::GetEncoding(28591))) {
        $n++
        if ($line -match '[^\x00-\x7F]') { $bad += "$($f.FullName):$n" }
    }
}
if ($bad) { throw "Non-ASCII characters found (Windows PowerShell 5.1 would misread them):`n  $($bad -join "`n  ")" }

# ---------------------------------------------------------------- copy

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$running = Get-RunningDevControl $Destination
Copy-Item -Force -Path (Join-Path $src '*') -Destination $Destination
foreach ($old in 'projects.default.json', 'presets.default.json', 'New-SigningCert.ps1', 'Install_fixes.md') {
    $p = Join-Path $Destination $old
    if (Test-Path $p) { Remove-Item -Force $p }
}
Write-Step "copied $(@(Get-ChildItem $src -File).Count) files to $Destination"

# ---------------------------------------------------------------- seed user files (never overwritten)

$settingsPath = Join-Path $Destination 'settings.json'
if (-not (Test-Path $settingsPath)) {
    $text = [IO.File]::ReadAllText((Join-Path $src 'settings.default.json'))
    $d = if ($Distro) { $Distro } else { Get-DefaultDistro }
    $text = Set-JsonField $text 'distro' $d
    if ($ProjectsRoot) { $text = Set-JsonField $text 'projectsRoot' $ProjectsRoot }
    $text = Set-JsonField $text 'modesDir' 'modes'
    Write-TextFile $settingsPath $text
    Write-Step "created settings.json (distro '$d', projectsRoot '$ProjectsRoot')"
} else {
    # Existing file: only fill values that are still empty.
    $text = [IO.File]::ReadAllText($settingsPath)
    $new = $text
    if ($Distro) { $new = Set-JsonField $new 'distro' $Distro }
    if ($ProjectsRoot) { $new = Set-JsonField $new 'projectsRoot' $ProjectsRoot }
    if ($new -ne $text) { Write-TextFile $settingsPath $new; Write-Step 'filled empty values in the existing settings.json' }
    else { Write-Step 'kept existing settings.json' }
}

$projectsPath = Join-Path $Destination 'projects.json'
if (-not (Test-Path $projectsPath)) {
    Copy-Item (Join-Path $src 'projects.example.json') $projectsPath
    Write-Step 'created projects.json from projects.example.json'
}

$modesDest = Join-Path $Destination 'modes'
New-Item -ItemType Directory -Force -Path $modesDest | Out-Null
foreach ($m in @(Get-ChildItem -Path (Join-Path $repo 'modes') -Filter '*.wslconfig' -ErrorAction SilentlyContinue)) {
    $to = Join-Path $modesDest $m.Name
    if (-not (Test-Path $to)) { Copy-Item $m.FullName $to; Write-Step "added mode $($m.BaseName)" }
}

# ---------------------------------------------------------------- build / sign / shortcuts

$exe = Join-Path $Destination 'DevControl.exe'
if ($Sign) { Initialize-SigningCert }
if ($Build -or -not (Test-Path $exe)) {
    # Icons held open by a running instance are kept (Install.ps1 swaps them via a temp file).
    & (Join-Path $Destination 'Install.ps1')
} elseif ($Sign) {
    & (Join-Path $Destination 'Install.ps1') -SignOnly
}
if (-not (Test-Path $exe)) { throw "$exe was not built." }

$ico = Join-Path $Destination 'DevControl.ico'
New-Shortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'Dev Control.lnk') $exe $Destination $ico
if (-not $NoDesktopShortcut) {
    New-Shortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Dev Control.lnk') $exe $Destination $ico
}

# ---------------------------------------------------------------- summary

$cfg = [IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
if (-not ([string]$cfg.projectsRoot).Trim()) {
    Write-Warning "projectsRoot is empty in $settingsPath - set it to the Linux folder holding your projects (or re-run with -ProjectsRoot /home/<you>/projects)."
}
if ($running.Count) {
    Write-Warning 'Dev Control is running the previous version - exit it (tray icon > Exit) and start it again to load this one.'
}
Write-Step "done. Start 'Dev Control' from the Start Menu."
