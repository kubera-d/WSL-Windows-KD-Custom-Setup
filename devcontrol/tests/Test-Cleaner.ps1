# Test-Cleaner.ps1 - the cleaner (Core.ps1 Invoke-DcCleanup + Cleaner.cs) against fixtures only:
#   two throwaway HTTP servers (127.0.0.1:4998 hosts the tabs, 4999 is idle), a throwaway Chromium on DevTools port
#   9333 (temp profile, headless) standing in for the automation Chrome, and two orphaned headless Chromiums (a
#   playwright_ profile, and one on its own DevTools port 9334).
# Nothing else is touched: -OnlyPorts / -OnlyPids, and a temp settings.json pointing the tab cleaner at 9333.
# Needs node and a Playwright Chromium (%LOCALAPPDATA%\ms-playwright). Safe while Dev Control runs.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Cleaner.ps1   (exit code = failures)
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path (Join-Path $PSScriptRoot '..\src')).Path
. (Join-Path $src 'Core.ps1')
Initialize-DcCleanerTypes
$work = Join-Path $env:TEMP ('dc-cleaner-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
'{ "cleanerChromePort": 9333, "kernelPoolWarnGB": 0.001 }' | Set-Content -Path (Join-Path $work 'settings.json')
$script:DcAppDir = $work
$script:DcDataDir = $work
$fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { "PASS  $Name" } else { $script:fails++; "FAIL  $Name  $Detail" }
}
function Start-Orphan([string]$File, [string]$Arguments) {
    # cmd starts the program and exits at once, so the program has no live parent (like a dev server whose session ended)
    $before = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c start "" /b "{0}" {1}' -f $File, $Arguments) -WindowStyle Hidden -PassThru
    $p.WaitForExit()
    Start-Sleep -Milliseconds 800
    $name = [IO.Path]::GetFileNameWithoutExtension($File)
    @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
}
function Http([string]$Method, [string]$Url) {
    $req = [Net.HttpWebRequest]::Create($Url); $req.Method = $Method; $req.Proxy = $null; $req.Timeout = 5000
    $resp = $req.GetResponse(); $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $t = $sr.ReadToEnd(); $resp.Close(); $t
}
$made = New-Object System.Collections.ArrayList
try {
    # ---- fixtures
    @'
const http = require('http'); const port = +process.argv[2];
http.createServer((q, s) => {
  s.setHeader('content-type', 'text/html');
  s.end('<title>fixture ' + q.url + '</title>' + (q.url === '/self' ? '<script>setTimeout(() => { location.href = "/moved" }, 1500)</script>' : 'ok'));
}).listen(port, '127.0.0.1');
'@ | Set-Content -Path (Join-Path $work 'server.js')
    $node = (Get-Command node.exe).Source
    $s1 = Start-Orphan $node ('"{0}" 4998' -f (Join-Path $work 'server.js')); $s1 | ForEach-Object { [void]$made.Add($_.Id) }
    $s2 = Start-Orphan $node ('"{0}" 4999' -f (Join-Path $work 'server.js')); $s2 | ForEach-Object { [void]$made.Add($_.Id) }
    $pw = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'ms-playwright') -Directory -Filter 'chromium-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    $chrome = @(Get-ChildItem -Path $pw.FullName -Recurse -Filter 'chrome.exe' -ErrorAction SilentlyContinue)[0].FullName
    $cp = Start-Process -FilePath $chrome -ArgumentList @('--remote-debugging-port=9333', "--user-data-dir=`"$work\chrome`"", '--headless=new', '--no-first-run', '--no-default-browser-check', 'about:blank') -PassThru
    [void]$made.Add($cp.Id)
    for ($i = 0; $i -lt 40; $i++) { try { [void](Http 'GET' 'http://127.0.0.1:9333/json/version'); break } catch { Start-Sleep -Milliseconds 250 } }
    # leftover browsers: a Playwright-profile Chromium whose script is gone (the Nov 11 case) and a headless Chromium on
    # its own DevTools port 9334 whose script is gone
    [void](Start-Orphan $chrome ('--headless=new --no-first-run --user-data-dir="{0}\playwright_chromiumdev_profile-test" about:blank' -f $work))
    [void](Start-Orphan $chrome ('--headless=new --no-first-run --remote-debugging-port=9334 --user-data-dir="{0}\port9334" about:blank' -f $work))
    Start-Sleep 2
    $orphMain = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { ($_.CommandLine -like "*$work\playwright_*" -or $_.CommandLine -like "*$work\port9334*") -and $_.CommandLine -notmatch '--type=' })
    $orphMain | ForEach-Object { [void]$made.Add([int]$_.ProcessId) }

    [DevControl.Cleaner.Watch]::Start($work, 9333)
    for ($i = 0; $i -lt 40 -and [DevControl.Cleaner.Watch]::TabStatus -notlike 'following*'; $i++) { Start-Sleep -Milliseconds 250 }
    Check 'watcher follows the test Chrome' ([DevControl.Cleaner.Watch]::TabStatus -like 'following*') ([DevControl.Cleaner.Watch]::TabStatus)

    # ---- tabs: A opened by a script with a URL, B blank, C navigated with no client attached (= the user), D driven by an attached client
    $a = Http 'PUT' 'http://127.0.0.1:9333/json/new?http://127.0.0.1:4998/a' | ConvertFrom-Json
    $b = Http 'PUT' 'http://127.0.0.1:9333/json/new?about:blank' | ConvertFrom-Json
    $c = Http 'PUT' 'http://127.0.0.1:9333/json/new?http://127.0.0.1:4998/self' | ConvertFrom-Json
    $d = Http 'PUT' 'http://127.0.0.1:9333/json/new?about:blank' | ConvertFrom-Json
    Start-Sleep 1
    $ws = New-Object Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$d.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
    $msg = [Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Page.navigate","params":{"url":"http://127.0.0.1:4998/d"}}')
    $ws.SendAsync((New-Object ArraySegment[byte] (, $msg)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
    Start-Sleep 2
    try { $ws.CloseAsync('NormalClosure', 'done', [Threading.CancellationToken]::None).Wait(5000) | Out-Null } catch { }
    $ws.Dispose()
    Start-Sleep 5   # C moves itself after 1.5 s; the watcher saves within 2 s

    $tf = Read-DcDataJson 'cleaner-tabs.json'
    $own = @{}; foreach ($pr in $tf.tabs.PSObject.Properties) { $own[$pr.Name] = $pr.Value.owner }
    Check 'tab A (opened by a script) is automation''s' ($own[$a.id] -eq 'auto') $own[$a.id]
    Check 'tab B (blank) is new' ($own[$b.id] -eq 'new') $own[$b.id]
    Check 'tab C (changed with no client attached) is the user''s' ($own[$c.id] -eq 'user') $own[$c.id]
    Check 'tab D (navigated while attached) is automation''s' ($own[$d.id] -eq 'auto') $own[$d.id]

    # ---- dev servers need a connection record: the watcher samples every 30 s and saves within a minute
    for ($i = 0; $i -lt 80; $i++) {
        $n = Read-DcDataJson 'cleaner-net.json'
        if ($n -and $n.servers -and @($n.servers.PSObject.Properties | Where-Object { $_.Name -like '*:4999' -or $_.Name -like '*:9334' }).Count -ge 2) { break }
        Start-Sleep 1
    }
    $pids = @($orphMain | ForEach-Object { [int]$_.ProcessId })
    $r = Invoke-DcCleanup -IdleHours 0 -OnlyPorts 4998, 4999 -OnlyPids $pids -Explain
    $r.Actions | ForEach-Object { "      action: $_" }
    $r.Kept | ForEach-Object { "      kept:   $_" }
    Start-Sleep 1
    $live = @{}; foreach ($t in (Http 'GET' 'http://127.0.0.1:9333/json/list' | ConvertFrom-Json)) { $live[[string]$t.id] = $t.url }
    Check 'closed tab A' (-not $live.ContainsKey($a.id))
    Check 'closed tab D' (-not $live.ContainsKey($d.id))
    Check 'kept tab B (blank)' ($live.ContainsKey($b.id))
    Check 'kept tab C (the user''s)' ($live.ContainsKey($c.id))
    Check 'stopped the idle server on 4999' (-not @($s2 | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue }).Count)
    Check 'kept the server on 4998 (a user tab is on it)' (@($s1 | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue }).Count -gt 0)
    Check 'two leftover browsers started' ($pids.Count -eq 2) "$($pids.Count)"
    Check 'stopped both leftover browsers' (-not @($pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count)
    Check 'kept the test Chrome on 9333 (the automation Chrome)' ([bool](Get-Process -Id $cp.Id -ErrorAction SilentlyContinue))
    Check 'kernel memory warning on the first pass' ([bool]$r.Warn)
    $r2 = Invoke-DcCleanup -IdleHours 0 -OnlyPorts 4998, 4999 -OnlyPids $pids
    Check 'no second warning in the same Windows start' (-not $r2.Warn) $r2.Warn
    $dr = Invoke-DcCleanup -DryRun -IdleHours 0 -OnlyPorts 4998
    Check 'dry run stops nothing' (@($s1 | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue }).Count -gt 0)
} finally {
    [DevControl.Cleaner.Watch]::Stop()
    foreach ($id in $made) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { } }
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*$work*" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
    Start-Sleep 1
    Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
}
"$fails failure(s)"
exit $fails
