<#
.SYNOPSIS
  Runs the UI self-test against the INSTALLED Dev Control (run Deploy.ps1 first).

.DESCRIPTION
  WSL must already be running and projectsRoot must be set in settings.json.
  The test never shuts WSL down and never quits VS Code (those prompts are answered No).
  It creates throwaway fixture projects (zz-devcontrol-selftest*) in projectsRoot, brings one
  compose project up and down, opens one fixture folder AND an empty window in VS Code (close
  them afterwards), and removes the fixtures at the end.
  Prints the PASS/FAIL lines from %LOCALAPPDATA%\DevControl\selftest.log. Exit code = failures.
  Keep this file ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs\DevControl'),
    [int]$TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
$app = Join-Path $Destination 'DevControl.ps1'
$log = Join-Path $env:LOCALAPPDATA 'DevControl\selftest.log'
if (-not (Test-Path $app)) { Write-Host "FAIL  Dev Control is not installed at $Destination (run Deploy.ps1)."; exit 1 }

$started = Get-Date
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$p = Start-Process -FilePath $psExe -WindowStyle Hidden -PassThru `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$app`" -SelfTest"
$null = $p.Handle   # keeps ExitCode available after exit
if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    try { $p.Kill() } catch { }
    Write-Host "FAIL  self-test did not finish within $TimeoutSeconds s (killed)."
    exit 1
}
$rc = $p.ExitCode

if (-not (Test-Path $log) -or (Get-Item $log).LastWriteTime -lt $started) {
    Write-Host "FAIL  no fresh $log - the app probably failed at startup (exit $rc)."
    Write-Host "      Run it directly to see the error: powershell -NoProfile -ExecutionPolicy Bypass -STA -File `"$app`" -SelfTest"
    Write-Host "      and check $(Join-Path $env:LOCALAPPDATA 'DevControl\app.log')."
    exit $(if ($rc) { $rc } else { 1 })
}
Get-Content $log | Where-Object { $_ -match '^(PASS|FAIL)|passed' }
exit $rc
