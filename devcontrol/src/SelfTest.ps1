# SelfTest.ps1 - drives the real UI (clicks buttons via UI Automation) against the live WSL.
# Dot-sourced by DevControl.ps1 when started with -SelfTest. Requires WSL to be RUNNING.
# Never runs wsl --shutdown: every shutdown / mode-switch prompt is answered No / Cancel.
# Never quits VS Code either: that prompt is answered No (it would kill the terminal, and any
# Claude Code session, that started the test).
# Depends on nobody's real projects: it creates throwaway FIXTURE folders zz-devcontrol-selftest*
# in projectsRoot (a compose project with alpine + a 'sleep' tool, a clone with the same compose
# name, a plain folder, a pinned project in another mode, a git repo + worktree, a compose-disabled
# project, a hidden one), runs against a generated projects.json in %TEMP% (the real one is never
# written), and removes the fixtures at the end.
# Results: %LOCALAPPDATA%\DevControl\selftest.log, process exit code = number of failures.

Add-Type -AssemblyName UIAutomationProvider, UIAutomationTypes

$script:TestExitCode = 0
$script:TestResults = New-Object System.Collections.ArrayList
$script:TestSteps = New-Object System.Collections.Queue
$script:TestCur = $null
$script:Answers = New-Object System.Collections.Queue
$script:Asked = New-Object System.Collections.ArrayList
$script:ConfirmHook = {
    param($msg, $title, $kind)
    [void]$script:Asked.Add($title)
    $a = if ($script:Answers.Count) { $script:Answers.Dequeue() } elseif ($kind -eq 'yesno') { $false } else { 'Cancel' }
    Log "[selftest] $kind '$title' -> $a"
    $a
}

if (-not $settings.projectsRoot) { throw "selftest: $DcNoProjectsRoot" }
$Root = $settings.projectsRoot.TrimEnd('/')
$StartMode = (Get-DcCurrentMode).Mode
$OtherMode = @(Get-DcModes | Where-Object { $_ -ne $StartMode })[0]
if (-not $OtherMode) { throw "selftest: needs at least two modes in $($settings.modesDir) (one other than the current '$StartMode')" }
function Get-WslCfgHash { if (Test-Path $settings.wslConfigPath) { (Get-FileHash $settings.wslConfigPath).Hash } else { 'missing' } }
$WslCfgHash = Get-WslCfgHash
$CallLog = Join-Path $DcDataDir 'wsl-calls.log'

# ---- fixture projects (folders in projectsRoot, all named zz-devcontrol-selftest*)
$TestProject  = 'zz-devcontrol-selftest'            # compose (services a, b) + tools; pinned; really run
$TestSlug     = Get-DcSlug $TestProject
$TestDir      = "$Root/$TestProject"
$CloneProject = "$TestProject-clone"                # same compose name as the test project -> guard
$PlainProject = "$TestProject-plain"                # no compose file, no projects.json entry -> group New
$ModeProject  = "$TestProject-mode"                 # pinned, compose, mode = another mode (never really run)
$RepoProject  = "$TestProject-repo"                 # git repo, compose: true + services subset
$WtProject    = "$TestProject-wt"                   # git worktree of the repo (same compose name)
$NoComposeProject = "$TestProject-nocompose"        # compose: false + warning
$HiddenProject = "$TestProject-hidden"              # hidden: true -> never listed
$GroupA = 'Selftest Active'; $GroupB = 'Selftest Tools'
$FixtureWarning = 'Selftest fixture warning'

$setup = @'
set -e
cd __ROOT__
t=__T__
yaml() {
  printf 'name: %s\nservices:\n  a:\n    image: alpine:latest\n    command: ["sleep", "infinity"]\n    init: true\n  b:\n    image: alpine:latest\n    command: ["sleep", "infinity"]\n    init: true\n' "$1"
}
rm -rf "$t-repo" "$t-wt"   # leftovers of an aborted run
mkdir -p "$t" "$t-clone" "$t-plain" "$t-mode" "$t-nocompose" "$t-hidden" "$t-repo"
yaml devcontrol-selftest > "$t/compose.yaml"
cp "$t/compose.yaml" "$t-clone/compose.yaml"
yaml devcontrol-selftest-mode > "$t-mode/compose.yaml"
yaml devcontrol-selftest-nocompose > "$t-nocompose/compose.yaml"
yaml devcontrol-selftest-repo > "$t-repo/compose.yaml"
git -C "$t-repo" init -q
git -C "$t-repo" add compose.yaml
git -C "$t-repo" -c user.name=selftest -c user.email=selftest@example.invalid -c commit.gpgsign=false commit -qm fixture
git -C "$t-repo" worktree add -q -b "$t-wt" "../$t-wt"
echo setup-done
'@
$setup = $setup.Replace('__ROOT__', (ConvertTo-DcBashLiteral $Root)).Replace('__T__', (ConvertTo-DcBashLiteral $TestProject))
$r = Invoke-DcLinux $setup 120
if ($r.ExitCode -ne 0) { throw "selftest setup failed: $($r.Err)$($r.Out)" }

# ---- generated projects.json in %TEMP% (the arrangement tests edit it); ui-state.json too.
$RealConfigPath = Join-Path $AppDir 'projects.json'
$RealConfigHash = if (Test-Path $RealConfigPath) { (Get-FileHash $RealConfigPath).Hash } else { '' }
$TestConfigPath = Join-Path $env:TEMP 'devcontrol-selftest-projects.json'
[Environment]::SetEnvironmentVariable('DEVCONTROL_PROJECTS_JSON', $TestConfigPath, 'Process')
$script:UiStatePath = Join-Path $env:TEMP 'devcontrol-selftest-ui-state.json'
Remove-Item -Force $script:UiStatePath -ErrorAction SilentlyContinue
$script:GroupExpanded = @{}; $script:ShowHidden = $false; $ui.ShowHiddenBox.IsChecked = $false
$help = @('Self-test fixture config (generated).')
$example = Join-Path $AppDir 'projects.example.json'
if (Test-Path $example) { try { $help = @((Get-Content -Raw -Encoding UTF8 $example | ConvertFrom-Json)._help) } catch { } }
$fixtureProjects = [ordered]@{}
$fixtureProjects[$TestProject] = [pscustomobject]@{
    mode = $StartMode; pinned = $true; openVSCode = $false; compose = $true
    tools = @(
        [pscustomobject]@{ name = 'Setup check'; command = 'echo setup-ok-$(basename "$PWD")' },
        [pscustomobject]@{ name = 'Dev Server'; command = 'sleep 1000'; background = $true }
    )
}
$fixtureProjects[$ModeProject]      = [pscustomobject]@{ group = $GroupA; order = 0; mode = $OtherMode; pinned = $true }
$fixtureProjects[$CloneProject]     = [pscustomobject]@{ group = $GroupA; order = 1 }
$fixtureProjects[$NoComposeProject] = [pscustomobject]@{ group = $GroupA; order = 2; compose = $false; warning = $FixtureWarning }
$fixtureProjects[$RepoProject]      = [pscustomobject]@{ group = $GroupB; order = 0; compose = $true; services = @('a') }
$fixtureProjects[$HiddenProject]    = [pscustomobject]@{ hidden = $true }
$tc = [pscustomobject]@{
    _help     = $help
    groups    = @($GroupA, $GroupB)
    collapsed = @()
    projects  = [pscustomobject]$fixtureProjects
}
Save-DcConfigFile $tc
Import-Config -Quiet

$script:PromptAnswers = New-Object System.Collections.Queue
$script:PromptHook = { param($title, $prompt, $default) $a = if ($script:PromptAnswers.Count) { $script:PromptAnswers.Dequeue() } else { $null }; Log "[selftest] prompt '$title' -> $a"; $a }
function Find-MenuItem($Menu, [string[]]$Path) {
    $items = $Menu.Items
    $mi = $null
    foreach ($h in $Path) {
        $mi = @($items | Where-Object { $_ -is [Windows.Controls.MenuItem] -and [string]$_.Header -eq $h })[0]
        if (-not $mi) { throw "menu item not found: $($Path -join ' > ')" }
        $items = $mi.Items
    }
    $mi
}
function Invoke-MenuPath($Menu, [string[]]$Path) {
    $mi = Find-MenuItem $Menu $Path
    if (-not $mi.IsEnabled) { throw "menu item disabled: $($Path -join ' > ')" }
    $mi.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.MenuItem]::ClickEvent, $mi)))
}
function Get-FileCfg { Get-DcConfigFile }
function Get-Members([string]$g) { @(Get-GroupMembers $g) }

function T([string]$Name, [scriptblock]$Act, [scriptblock]$Until, [int]$Timeout = 60) {
    $script:TestSteps.Enqueue(@{ Name = $Name; Act = $Act; Until = $Until; Timeout = $Timeout })
}
function Test-Idle { -not $script:Busy -and -not $script:PendingLifecycle -and -not $script:Seq -and (Get-JobCount 'action') -eq 0 }
function Test-LogHas([string]$Pattern) { @($script:TestLog | Where-Object { $_ -like "*$Pattern*" }).Count -gt 0 }
function Get-LogCount([string]$Pattern) { @($script:TestLog | Where-Object { $_ -like "*$Pattern*" }).Count }
function Get-Descendants($root) {
    $n = [Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
    for ($i = 0; $i -lt $n; $i++) { $c = [Windows.Media.VisualTreeHelper]::GetChild($root, $i); $c; Get-Descendants $c }
}
function Find-ItemButton($list, [string]$Uid, [string]$Tag) {
    Get-Descendants $list | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Uid -eq $Uid -and [string]$_.Tag -eq $Tag } | Select-Object -First 1
}
# Real click through UI Automation (throws if the button is disabled).
function Invoke-Click($btn) {
    $peer = New-Object Windows.Automation.Peers.ButtonAutomationPeer $btn
    ([Windows.Automation.Provider.IInvokeProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Invoke)).Invoke()
}
function Click-Item($list, [string]$Uid, [string]$Tag) {
    $b = Find-ItemButton $list $Uid $Tag
    if (-not $b -or -not $b.IsEnabled) { return $false }
    Invoke-Click $b
    return $true
}
function Get-TestRow { @($ui.ProjectList.ItemsSource) | Where-Object { $_.Name -eq $TestProject } | Select-Object -First 1 }
function Get-TestContainers { , @($script:Containers | Where-Object { $_.Dir -eq $TestDir }) }
function Get-TestTools { , @($script:Tools | Where-Object { $_.Slug -eq $TestSlug -and $_.Running }) }

# ------------------------------------------------------------------ steps

T 'Status shows WSL running, memory and mode' {} {
    $script:State.Running -eq $true -and $ui.WslText.Text -eq 'WSL: Running' -and
    $ui.MemText.Text -match '(GB|MB)$' -and $ui.ModeText.Text -like "Mode: $StartMode*" -and $ui.LiveText.Text -match 'CPU'
}

T "Projects listed; $ModeProject shows its mode tag and is pinned" { Show-Projects } {
    $rows = @($ui.ProjectList.ItemsSource)
    $pm = $rows | Where-Object { $_.Name -eq $ModeProject }
    -not $script:ProjectsCached -and (Get-TestRow) -and $pm -and $pm.Mode -eq $OtherMode -and $pm.HasMode -and $pm.ShowRun -and
    @($ui.PinnedList.ItemsSource | Where-Object { $_.Name -eq $ModeProject }).Count -eq 1 -and
    @($ui.PinnedList.ItemsSource | Where-Object { $_.Name -eq $TestProject }).Count -eq 1
}

T 'Classification: worktree / compose:false / name clash have no Run; services subset; hidden not listed' {} {
    $rows = @($ui.ProjectList.ItemsSource)
    $row = { param($n) $rows | Where-Object { $_.Name -eq $n } | Select-Object -First 1 }
    $wt = & $row $WtProject; $noc = & $row $NoComposeProject; $repo = & $row $RepoProject; $clone = & $row $CloneProject
    $repoCompose = @(Get-SequenceSteps 'run' $RepoProject | Where-Object { $_.Type -eq 'compose' })
    $wtSteps = Get-SequenceSteps 'run' $WtProject
    $wt -and -not $wt.ShowRun -and $wt.Group -eq "$RepoProject worktrees" -and $wt.Info -like '*safe to remove*' -and $wt.HasWarning -and
    @($wtSteps | Where-Object { $_.Type -eq 'compose' }).Count -eq 0 -and
    $noc -and -not $noc.ShowRun -and $noc.Warning -like "*$FixtureWarning*" -and
    $repo -and $repo.ShowRun -and $repo.Group -eq $GroupB -and $repoCompose.Count -eq 1 -and ($repoCompose[0].Services -join ',') -eq 'a' -and
    $clone -and -not $clone.ShowRun -and $clone.Warning -like "*also used by $TestProject*" -and
    -not @($rows | Where-Object { $_.Name -eq $HiddenProject }).Count
}

T 'A plain folder (no compose file, not in projects.json) is listed in group New' { Update-Projects } {
    $row = @($ui.ProjectList.ItemsSource) | Where-Object { $_.Name -eq $PlainProject } | Select-Object -First 1
    $row -and $row.Group -eq 'New' -and -not $row.ShowRun -and $row.Status -eq 'editor only' -and $row.CanCode -and
    (Get-GroupRank 'New') -lt (Get-GroupRank $GroupA)
} 60

T 'Start WSL in current mode is a no-op' {
    $script:Asked.Clear(); $ui.ModeCombo.SelectedItem = $StartMode; Invoke-Click $ui.StartBtn
} { (Test-LogHas "already running in $StartMode") -and $script:Asked.Count -eq 0 -and (Test-Idle) }

T 'Start WSL with no mode picked is allowed (no-op while running)' {
    $script:Asked.Clear(); $ui.ModeCombo.SelectedItem = $null; Invoke-Click $ui.StartBtn
} {
    (Test-LogHas 'WSL is already running.') -and -not (Test-LogHas 'Pick a mode first') -and
    $script:Asked.Count -eq 0 -and (Test-Idle) -and (Get-WslCfgHash) -eq $WslCfgHash
}

T "Start WSL in '$OtherMode' asks to restart; No changes nothing" {
    $script:Asked.Clear(); $script:Answers.Enqueue($false); $ui.ModeCombo.SelectedItem = $OtherMode; Invoke-Click $ui.StartBtn
} {
    (Test-LogHas "Cancelled switching to $OtherMode") -and $script:Asked -contains 'Switch mode' -and (Test-Idle) -and
    (Get-WslCfgHash) -eq $WslCfgHash -and $script:State.Running
}

T 'Stop WSL asks first; No keeps WSL running' {
    $script:Asked.Clear(); $script:Answers.Enqueue($false); $ui.ModeCombo.SelectedItem = $StartMode; Invoke-Click $ui.StopWslBtn
} { (Test-LogHas 'Stop WSL cancelled') -and $script:Asked -contains 'Stop WSL' -and (Test-Idle) -and $script:State.Running }

T 'Run test project (projects list)' {} { Click-Item $ui.ProjectList 'run' $TestProject }
T 'Run: compose up, one-shot tool, background tool; containers + tool nested under project' {} {
    $row = Get-TestRow
    (Test-LogHas "== run $TestProject`: done") -and (Test-Idle) -and (Test-LogHas "setup-ok-$TestProject") -and
    (Get-TestContainers).Count -eq 2 -and (Get-TestTools).Count -eq 1 -and
    $row.Children.Count -eq 3 -and $row.Status -like 'running*2 container(s), 1 tool(s)' -and
    @($row.Children | Where-Object { $_.Cpu -match '%' }).Count -eq 3 -and -not (Test-LogHas 'Opening zz-devcontrol')
} 180

T 'Background tool survives its wsl.exe call (still alive 12s later)' { $script:T0 = Get-Date } {
    ((Get-Date) - $script:T0).TotalSeconds -gt 12 -and -not (Test-Job 'runtime') -and (Get-TestTools).Count -eq 1
} 40

T 'Stop the tool from its nested row' {} { Click-Item $ui.ProjectList 'child' "t:$TestSlug/dev-server" }
T 'Tool stopped, containers untouched' {} {
    (Test-Idle) -and (Test-LogHas 'Tools: stopped dev-server') -and (Get-TestTools).Count -eq 0 -and (Get-TestContainers).Count -eq 2
} 40

T 'Restart project (compose restart + background tool back)' {} { Click-Item $ui.ProjectList 'restart' $TestProject }
T 'Restart done' {} {
    (Test-LogHas "== restart $TestProject`: done") -and (Test-Idle) -and (Get-TestTools).Count -eq 1 -and (Get-TestContainers).Count -eq 2
} 120

T 'Stop one container from its nested row' { $script:VictimId = ((Get-TestContainers) | Sort-Object Name | Select-Object -First 1).Id } {
    Click-Item $ui.ProjectList 'child' "c:$($script:VictimId)"
}
T 'Container gone, the other still running' {} {
    (Test-Idle) -and (Get-TestContainers).Count -eq 1 -and (Get-TestContainers)[0].Id -ne $script:VictimId
} 60

T 'Stop project (tools + compose down)' {} { Click-Item $ui.ProjectList 'stop' $TestProject }
T 'Stop done: no containers, no tools, status stopped' {} {
    (Test-LogHas "== stop $TestProject`: done") -and (Test-Idle) -and (Get-TestContainers).Count -eq 0 -and
    (Get-TestTools).Count -eq 0 -and (Get-TestRow).Status -eq 'stopped'
} 120

T 'Run from the Pinned panel' { $script:RunCount = Get-LogCount "== run $TestProject`: done" } { Click-Item $ui.PinnedList 'run' $TestProject }
T 'Pinned Run done' {} {
    (Get-LogCount "== run $TestProject`: done") -gt $script:RunCount -and (Test-Idle) -and (Get-TestContainers).Count -eq 2
} 120

T 'Compose guard refuses up when another folder owns the compose name' {
    $script:GuardUp = $null
    Start-Bg -Name 'guardup' -Kind 'action' -Work { param($n) Invoke-DcCompose $n 'up' } -ArgList @("$TestProject-clone") -Done {
        param($r, $e) $script:GuardUp = if ($e) { $e.Message } else { 'NO ERROR' }
    }
} { $script:GuardUp -like '*REFUSED*' -and $script:GuardUp -like "*$TestDir*" -and (Get-TestContainers).Count -eq 2 } 60

T 'Stop all containers (asks, Yes)' {
    $others = @($script:Containers | Where-Object { $_.Dir -ne $TestDir })
    if ($others.Count) { Log "[selftest] SKIP stop-all: $($others.Count) of your own containers are running"; $script:SkipStopAll = $true; return }
    $script:Asked.Clear(); $script:Answers.Enqueue($true); Invoke-Click $ui.StopAllBtn
} { $script:SkipStopAll -or ((Test-LogHas 'Stopped 2 container(s)') -and (Test-Idle) -and $script:Containers.Count -eq 0 -and $script:Asked -contains 'Stop all containers') } 60

T 'Stop project again (cleans up the tool)' {} { Click-Item $ui.PinnedList 'stop' $TestProject }
T 'Cleanup stop done' {} { (Get-LogCount "== stop $TestProject`: done") -ge 2 -and (Test-Idle) -and (Get-TestTools).Count -eq 0 } 120

T "Run $ModeProject`: asks about its mode; Cancel aborts before compose" {
    $script:Asked.Clear(); $script:Answers.Enqueue('Cancel')
    [void](Click-Item $ui.PinnedList 'run' $ModeProject)
} {
    (Test-LogHas "== run $ModeProject`: stopped at step 1") -and (Test-Idle) -and $script:Asked -contains 'Switch mode' -and
    -not (Test-LogHas "docker compose up - $ModeProject") -and (Get-WslCfgHash) -eq $WslCfgHash
}

T "VS Code button ($ModeProject)" {} { Click-Item $ui.ProjectList 'code' $ModeProject }
T 'VS Code launched' {} { (Test-LogHas "Opened $Root/$ModeProject in VS Code") -and (Test-Idle) } 40

T 'Open VS Code with no folder' { Invoke-Click $ui.CodeOpenBtn } {
    (Test-LogHas 'Opened an empty VS Code window') -and (Test-Idle)
} 40

T 'VS Code is detected as running in WSL (Quit button enabled)' { Update-Runtime } {
    $script:VSCodeCount -gt 0 -and $ui.CodeQuitBtn.IsEnabled -and $ui.CodeText.Text -like 'Running in WSL*'
} 60

# Never answered Yes: quitting VS Code would kill the terminal (and Claude Code session) that
# started this test, exactly like wsl --shutdown.
T 'Quit VS Code asks first; No leaves it running' {
    $script:Asked.Clear(); $script:Answers.Enqueue($false); Invoke-Click $ui.CodeQuitBtn
} {
    (Test-LogHas 'Quit VS Code cancelled') -and $script:Asked -contains 'Quit VS Code' -and (Test-Idle) -and
    -not (Test-LogHas 'Quitting VS Code in WSL') -and $script:VSCodeCount -gt 0
} 30

T 'Reload projects.json' { $script:Loads = Get-LogCount 'Loaded projects.json'; Invoke-Click $ui.ReloadConfigBtn } {
    (Get-LogCount 'Loaded projects.json') -gt $script:Loads -and (Test-Pinned $ModeProject)
}

T 'Arrange: move project to a NEW group via its menu (persisted to projects.json)' {
    $script:PromptAnswers.Enqueue('Selftest Group')
    Invoke-MenuPath (New-ProjectMenu $TestProject) @('Move to group', 'New group...')
} {
    $f = Get-FileCfg
    (Get-TestRow).Group -eq 'Selftest Group' -and $f.projects.$TestProject.group -eq 'Selftest Group' -and @($f.groups) -contains 'Selftest Group' -and
    @($f._help).Count -gt 5
}

T 'Arrange: rename the group from its header menu' {
    $script:PromptAnswers.Enqueue('Selftest Renamed')
    Invoke-MenuPath (New-GroupMenu 'Selftest Group') @('Rename group...')
} {
    $f = Get-FileCfg
    (Get-TestRow).Group -eq 'Selftest Renamed' -and @($f.groups) -contains 'Selftest Renamed' -and @($f.groups) -notcontains 'Selftest Group' -and
    (Get-DisplayGroups) -notcontains 'Selftest Group'
}

T 'Arrange: move the group up' { $script:GIdx = [array]::IndexOf((Get-DisplayGroups), 'Selftest Renamed'); Invoke-MenuPath (New-GroupMenu 'Selftest Renamed') @('Move group up') } {
    [array]::IndexOf((Get-DisplayGroups), 'Selftest Renamed') -eq $script:GIdx - 1 -and
    [array]::IndexOf(@((Get-FileCfg).groups), 'Selftest Renamed') -lt [array]::IndexOf(@((Get-FileCfg).groups), (Get-DisplayGroups)[$script:GIdx])
}

T "Arrange: move $ModeProject down within $GroupA" {
    $script:ActiveBefore = Get-Members $GroupA
    Invoke-MenuPath (New-ProjectMenu $ModeProject) @('Move down')
} {
    $b = $script:ActiveBefore; $i = [array]::IndexOf($b, $ModeProject); $now = Get-Members $GroupA
    $b.Count -ge 3 -and [array]::IndexOf($now, $ModeProject) -eq $i + 1 -and $now[$i] -eq $b[$i + 1] -and
    (Get-FileCfg).projects.$ModeProject.order -eq $i + 1
}

T "Arrange: drop $ModeProject on the $GroupA header (-> last), then on the first card (-> first)" {
    $grp = @($ui.ProjectList.ItemsSource.Groups | Where-Object { $_.Name -eq $GroupA })[0]
    Invoke-ProjectDrop $ModeProject $grp $false
    $script:AfterHeader = Get-Members $GroupA
    $first = Get-RowByName ((Get-Members $GroupA)[0])
    Invoke-ProjectDrop $ModeProject $first $false
} {
    $script:AfterHeader[-1] -eq $ModeProject -and (Get-Members $GroupA)[0] -eq $ModeProject
}

T 'Arrange: drop a project into another group (card target, after)' {
    $t = Get-RowByName ((Get-Members $GroupB)[0])
    Invoke-ProjectDrop $NoComposeProject $t $true
} { (Get-RowByName $NoComposeProject).Group -eq $GroupB -and (Get-Members $GroupB)[1] -eq $NoComposeProject -and (Get-FileCfg).projects.$NoComposeProject.group -eq $GroupB }

T 'Arrange: unpin from the menu (then pin again)' { Invoke-MenuPath (New-ProjectMenu $TestProject) @('Unpin') } {
    if (@($ui.PinnedList.ItemsSource | Where-Object { $_.Name -eq $TestProject }).Count) { return $false }
    Invoke-MenuPath (New-ProjectMenu $TestProject) @('Pin')
    $true
} 10
T 'Arrange: pinned again' {} { @($ui.PinnedList.ItemsSource | Where-Object { $_.Name -eq $TestProject }).Count -eq 1 -and (Get-FileCfg).projects.$TestProject.pinned }

T 'Arrange: hide -> gone; Show hidden -> dimmed; Unhide' { Invoke-MenuPath (New-ProjectMenu $NoComposeProject) @('Hide') } {
    if ((Get-RowByName $NoComposeProject) -and -not $script:ShowHidden) { return $false }
    if (-not $script:ShowHidden) { $ui.ShowHiddenBox.IsChecked = $true; $ui.ShowHiddenBox.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); return $false }
    $r = Get-RowByName $NoComposeProject
    if (-not ($r -and $r.IsHiddenRow -and $r.Info -like 'hidden*')) { return $false }
    Invoke-MenuPath (New-ProjectMenu $NoComposeProject) @('Unhide')
    $true
}
T 'Arrange: unhidden and Show hidden remembered' {} {
    $r = Get-RowByName $NoComposeProject
    $r -and -not $r.IsHiddenRow -and -not (Get-FileCfg).projects.$NoComposeProject.PSObject.Properties['hidden'] -and
    ((Get-Content -Raw $script:UiStatePath | ConvertFrom-Json).showHidden -eq $true)
}

T 'Arrange: collapsing/expanding a group is remembered after a restart' {
    $ex = Get-Descendants $ui.ProjectList | Where-Object { $_ -is [Windows.Controls.Expander] -and [string]$_.Tag -eq $GroupB } | Select-Object -First 1
    $script:GroupBWas = $ex.IsExpanded
    $ex.IsExpanded = -not $ex.IsExpanded
} {
    $saved = Get-Content -Raw $script:UiStatePath | ConvertFrom-Json
    $script:GroupExpanded = @{}; Import-UiState          # what a fresh start does
    $saved.expanded.$GroupB -eq (-not $script:GroupBWas) -and (Test-GroupExpanded $GroupB) -eq (-not $script:GroupBWas)
}

T 'Arrange: ungroup -> back to the default group, group removed' { Invoke-MenuPath (New-GroupMenu 'Selftest Renamed') @('Ungroup (projects go back to their default group)') } {
    (Get-TestRow).Group -eq 'Other' -and @((Get-FileCfg).groups) -notcontains 'Selftest Renamed' -and -not (Get-FileCfg).projects.$TestProject.PSObject.Properties['group']
}

T 'Arrange: settings survive a reload from disk' { Import-Config -Quiet } {
    (Get-Members $GroupA)[0] -eq $ModeProject -and (Get-RowByName $NoComposeProject).Group -eq $GroupB
}

T 'Tray: Run submenu lists pinned; Start WSL (current) no-op; Stop WSL (No); Quit VS Code (No)' {
    $script:Answers.Enqueue($false); $script:Answers.Enqueue($false)
    ($script:TrayItems.Start.DropDownItems | Where-Object { $_.Tag -eq $StartMode }).PerformClick()
    $script:TrayItems.Stop.PerformClick()
    $script:TrayItems.CodeQuit.PerformClick()
} {
    @($script:TrayItems.Run.DropDownItems | ForEach-Object { $_.Text }) -contains $ModeProject -and
    (Get-LogCount "already running in $StartMode") -ge 2 -and (Get-LogCount 'Stop WSL cancelled') -ge 2 -and
    (Get-LogCount 'Quit VS Code cancelled') -ge 2 -and $script:State.Running -and $script:VSCodeCount -gt 0
}

T 'Minimize hides to tray, tray Open restores' { $win.WindowState = 'Minimized' } {
    if ($win.IsVisible) { return $false }
    $script:TrayItems.Open.PerformClick()
    $win.IsVisible -and $win.WindowState -eq 'Normal'
}

# Simulated stop: Test-DcWslRunning reports false, so we can check the UI state and that
# nothing tries to run a Linux command (which in real life would boot WSL).
T 'Simulated stop: WSL: Stopped, Run + VS Code enabled (they start WSL), Stop disabled' {
    $script:CallLogLines = @(Get-Content $CallLog).Count
    $script:FakeSince = Get-Date
    [Environment]::SetEnvironmentVariable('DEVCONTROL_FAKE_STOPPED', '1', 'Process')
} {
    $pa = @($ui.ProjectList.ItemsSource) | Where-Object { $_.Name -eq $ModeProject }
    $ui.WslText.Text -eq 'WSL: Stopped' -and $ui.MemText.Text -eq 'Memory: -' -and $script:Containers.Count -eq 0 -and
    -not $ui.StopWslBtn.IsEnabled -and $ui.StartBtn.IsEnabled -and -not $ui.StopAllBtn.IsEnabled -and -not $ui.RefreshBtn.IsEnabled -and
    -not $ui.CodeQuitBtn.IsEnabled -and $ui.CodeOpenBtn.IsEnabled -and $ui.CodeText.Text -like 'WSL is stopped*' -and
    $pa.CanRun -and -not $pa.CanAct -and $pa.CanCode -and $pa.Status -eq 'WSL stopped' -and
    (Find-ItemButton $ui.ProjectList 'run' $ModeProject).IsEnabled -and
    -not (Find-ItemButton $ui.ProjectList 'stop' $ModeProject).IsEnabled
} 20

T 'Simulated stop: no Linux calls for 35s (refresh timers fire)' {} {
    if (((Get-Date) - $script:FakeSince).TotalSeconds -lt 35) { return $false }
    $new = @(Get-Content $CallLog | Select-Object -Skip $script:CallLogLines)
    $bad = @($new | Where-Object { $_ -match "\[$PID\]\s+(LINUX|BOOT|CODE|SHUT)\s" })
    if ($bad) { throw "Linux calls while stopped: $($bad -join ' || ')" }
    $true
} 60

T 'Simulated stop: guarded Linux call refuses' {
    Start-Bg -Name 'guardtest' -Kind 'poll' -Work { Get-DcRuntime } -Done { param($r, $e) $script:GuardErr = if ($e) { $e.Message } else { 'NO ERROR' } }
} { $script:GuardErr -like '*refusing to run a Linux command*' } 20

T 'Your real projects.json and ui-state.json were not touched' {} {
    if ($RealConfigHash) { (Test-Path $RealConfigPath) -and (Get-FileHash $RealConfigPath).Hash -eq $RealConfigHash }
    else { -not (Test-Path $RealConfigPath) }
}

T 'Back to running: lists reload' { [Environment]::SetEnvironmentVariable('DEVCONTROL_FAKE_STOPPED', $null, 'Process') } {
    $ui.WslText.Text -eq 'WSL: Running' -and -not $script:ProjectsCached -and $ui.StopWslBtn.IsEnabled -and
    (Find-ItemButton $ui.ProjectList 'stop' $ModeProject).IsEnabled
} 30

# ------------------------------------------------------------------ driver

function Complete-SelfTest {
    $script:TestTimer.Stop()
    try {
        [void](Stop-DcTools $TestSlug)
        # Only the fixture folders this test created (fixed zz-devcontrol-selftest* names).
        $cleanup = @'
cd __ROOT__ || exit 0
t=__T__
(cd "$t" && docker compose down >/dev/null 2>&1)
git -C "$t-repo" worktree remove --force "../$t-wt" >/dev/null 2>&1
rm -rf "$t" "$t-clone" "$t-plain" "$t-mode" "$t-nocompose" "$t-hidden" "$t-repo" "$t-wt"
rm -rf "$HOME/.cache/devcontrol/run/__SLUG__"
'@
        $cleanup = $cleanup.Replace('__ROOT__', (ConvertTo-DcBashLiteral $Root)).Replace('__T__', (ConvertTo-DcBashLiteral $TestProject)).Replace('__SLUG__', $TestSlug)
        [void](Invoke-DcLinux $cleanup 120)
    } catch { }
    [Environment]::SetEnvironmentVariable('DEVCONTROL_PROJECTS_JSON', $null, 'Process')
    Remove-Item -Force $TestConfigPath, "$TestConfigPath.bak", $script:UiStatePath -ErrorAction SilentlyContinue
    $fails = @($script:TestResults | Where-Object { $_ -like 'FAIL*' }).Count
    $script:TestExitCode = $fails
    $out = @("Dev Control self-test  $(Get-Date -Format s)", '') + $script:TestResults + @('', "$($script:TestResults.Count - $fails) passed, $fails failed", '', '--- app log ---') + $script:TestLog
    Set-Content -Path (Join-Path $DcDataDir 'selftest.log') -Value $out -Encoding UTF8
    Exit-App
}

$script:TestTimer = New-Object Windows.Threading.DispatcherTimer
$script:TestTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$script:TestTimer.add_Tick({
    $cur = $script:TestCur
    if (-not $cur) {
        if ($script:TestSteps.Count -eq 0) { Complete-SelfTest; return }
        $cur = $script:TestSteps.Dequeue()
        $cur.Start = Get-Date
        $script:TestCur = $cur
        Log "[selftest] >> $($cur.Name)"
        try { & $cur.Act } catch { [void]$script:TestResults.Add("FAIL  $($cur.Name): action threw $($_.Exception.Message)"); $script:TestCur = $null }
        return
    }
    $ok = $false
    try { $ok = [bool](& $cur.Until) } catch { [void]$script:TestResults.Add("FAIL  $($cur.Name): $($_.Exception.Message)"); $script:TestCur = $null; return }
    $secs = ((Get-Date) - $cur.Start).TotalSeconds
    if ($ok) {
        [void]$script:TestResults.Add(('PASS  {0}  ({1:N1}s)' -f $cur.Name, $secs)); $script:TestCur = $null
    } elseif ($secs -gt $cur.Timeout) {
        [void]$script:TestResults.Add("FAIL  $($cur.Name): timed out after $($cur.Timeout)s"); $script:TestCur = $null
    }
})
$script:TestTimer.Start()
