# Install.ps1 - build step, runs on Windows from the INSTALLED folder (Deploy.ps1 calls it).
# 1. draws DevControl.ico / DevControl.png
# 2. compiles DevControl.exe (no-console launcher) with the built-in .NET Framework csc.exe
# 3. signs it with the local 'CN=KD Dev Tools' code-signing certificate, if there is one
#    (Deploy.ps1 -Sign creates it): a rebuilt exe has a new hash, so without this SmartScreen
#    prompts again after every rebuild.
# -SignOnly skips 1 and 2 (re-sign the existing exe). Shortcuts are created by Deploy.ps1.
# Idempotent. Keep this file ASCII-only.
param([switch]$SignOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$dir = $PSScriptRoot
$exe = Join-Path $dir 'DevControl.exe'
$signSubject = 'CN=KD Dev Tools'

# Signs the launcher with the code-signing cert, if it exists. Timestamped, so the signature
# keeps validating after the certificate expires; untimestamped fallback when offline.
function Set-DcSignature {
    $cert = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $signSubject -and $_.NotAfter -gt (Get-Date) } | Sort-Object NotAfter -Descending)[0]
    if (-not $cert) {
        Write-Host "Signed:   no '$signSubject' certificate in Cert:\CurrentUser\My - exe stays unsigned (SmartScreen may prompt). Run Deploy.ps1 -Sign once."
        return
    }
    $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256 `
        -TimeStampServer 'http://timestamp.digicert.com' -ErrorAction SilentlyContinue
    if (-not $sig -or $sig.Status -ne 'Valid') {
        $sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -HashAlgorithm SHA256
    }
    Write-Host "Signed:   $($sig.Status) ($signSubject)"
}

if ($SignOnly) {
    if (-not (Test-Path $exe)) { throw "$exe not found - run Deploy.ps1 -Build first." }
    Set-DcSignature
    return
}

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $r = [Math]::Max(2, [int]($size * 0.22))
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($size - 1), ($size - 1)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.X, $rect.Y, $r * 2, $r * 2, 180, 90)
    $path.AddArc($rect.Right - $r * 2, $rect.Y, $r * 2, $r * 2, 270, 90)
    $path.AddArc($rect.Right - $r * 2, $rect.Bottom - $r * 2, $r * 2, $r * 2, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $r * 2, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(255, 37, 99, 235)), ([System.Drawing.Color]::FromArgb(255, 13, 148, 136)), 45.0
    $g.FillPath($brush, $path)
    # ">_" prompt glyph drawn as strokes so it stays crisp at 16px
    $w = [Math]::Max(1.6, $size * 0.1)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $w
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $s = $size
    $g.DrawLines($pen, [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF ($s * 0.24), ($s * 0.30)),
        (New-Object System.Drawing.PointF ($s * 0.46), ($s * 0.50)),
        (New-Object System.Drawing.PointF ($s * 0.24), ($s * 0.70))))
    $g.DrawLine($pen, ($s * 0.54), ($s * 0.72), ($s * 0.78), ($s * 0.72))
    # status dot
    $d = $s * 0.2
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 74, 222, 128))), ($s * 0.70), ($s * 0.12), $d, $d)
    $g.Dispose()
    $bmp
}

# ICO with 32-bit DIB entries (works everywhere: csc /win32icon, WPF, WinForms NotifyIcon).
function Write-Ico([string]$path, [int[]]$sizes) {
    $images = foreach ($sz in $sizes) {
        $bmp = New-IconBitmap $sz
        $data = $bmp.LockBits((New-Object System.Drawing.Rectangle 0, 0, $sz, $sz), 'ReadOnly', ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb))
        $px = New-Object byte[] ($sz * $sz * 4)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
        $bmp.UnlockBits($data); $bmp.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter $ms
        $maskRow = [int]([Math]::Ceiling($sz / 32.0) * 4)
        $bw.Write([int]40); $bw.Write([int]$sz); $bw.Write([int]($sz * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
        $bw.Write([int]0); $bw.Write([int]($px.Length + $maskRow * $sz)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
        for ($y = $sz - 1; $y -ge 0; $y--) { $bw.Write($px, $y * $sz * 4, $sz * 4) }   # bottom-up BGRA
        $bw.Write((New-Object byte[] ($maskRow * $sz)))                                 # empty AND mask
        $bw.Flush()
        , @($sz, $ms.ToArray())
    }
    $fs = [System.IO.File]::Create($path)
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($im in $images) {
        $sz = $im[0]; $b = $im[1]
        $bw.Write([byte]($sz % 256)); $bw.Write([byte]($sz % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]$b.Length); $bw.Write([int]$offset)
        $offset += $b.Length
    }
    foreach ($im in $images) { $bw.Write([byte[]]$im[1]) }
    $bw.Close()
}

# The running app holds DevControl.ico / .png open (window icon, tray icon), so write to a
# temp file and swap: a locked icon then keeps the existing one instead of failing the install.
function Update-IconFile([string]$Path, [scriptblock]$Write) {
    $tmp = "$Path.new"
    & $Write $tmp
    try { Move-Item -Force $tmp $Path; $true }
    catch { Remove-Item -Force $tmp -ErrorAction SilentlyContinue; Write-Host "Icon:     $Path is in use (Dev Control is running) - kept the existing one."; $false }
}

$ico = Join-Path $dir 'DevControl.ico'
$okIco = Update-IconFile $ico { param($p) Write-Ico $p @(16, 20, 24, 32, 48, 64, 256) }
$okPng = Update-IconFile (Join-Path $dir 'DevControl.png') {
    param($p)
    $png = New-IconBitmap 128
    $png.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    $png.Dispose()
}
if ($okIco -and $okPng) { Write-Host "Icon:     $ico" }
if (-not (Test-Path $ico)) { throw "$ico is missing and could not be written" }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
# Compile next to the exe and swap it in: the exe is only held open for a moment while it
# launches the app (it exits right after), but never leave a half-written launcher behind.
$buildDir = Join-Path $env:TEMP 'devcontrol-build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$newExe = Join-Path $buildDir 'DevControl.exe'
Remove-Item -Force $newExe -ErrorAction SilentlyContinue
$out = & $csc /nologo /optimize /target:winexe "/out:$newExe" "/win32icon:$ico" (Join-Path $dir 'Launcher.cs') 2>&1
if ($LASTEXITCODE -ne 0) { throw "csc failed: $out" }
try { Move-Item -Force $newExe $exe }
catch {
    Remove-Item -Force $newExe -ErrorAction SilentlyContinue
    throw "$exe is in use - close Dev Control (tray icon > Exit) and run Deploy.ps1 again."
}
Write-Host "Launcher: $exe"
Set-DcSignature
