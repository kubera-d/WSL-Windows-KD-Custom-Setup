# DevControl.ps1 - WPF front end for managing WSL2 from Windows.
# Runs in Windows PowerShell 5.1 on the Windows side, so it keeps working after wsl --shutdown.
# Launched by DevControl.exe (no console window). Keep this file ASCII-only.
param([switch]$SelfTest, [switch]$Minimized)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$AppDir   = $PSScriptRoot
$CorePath = Join-Path $AppDir 'Core.ps1'
. $CorePath

# ---------------------------------------------------------------- single instance

$suffix = if ($SelfTest) { '.SelfTest' } else { '' }
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, "Local\DevControl$suffix", [ref]$createdNew)
$script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', "Local\DevControl.Show$suffix")
if (-not $createdNew) { [void]$script:ShowEvent.Set(); return }   # bring the running instance forward

if (-not ('DevControl.ChildRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
namespace DevControl {
  public class ChildRow {
    public string Icon {get;set;} public string Name {get;set;} public string Detail {get;set;}
    public string Cpu {get;set;} public string Mem {get;set;} public string Tag {get;set;}
    public string StatusColor {get;set;} public bool HasAction {get;set;} public bool CanAct {get;set;}
  }
  public class ProjectRow {
    public string Name {get;set;} public string Status {get;set;} public string ShortStatus {get;set;} public string StatusColor {get;set;}
    public string Mode {get;set;} public bool HasMode {get;set;} public bool IsProject {get;set;}
    public bool CanRun {get;set;} public bool CanAct {get;set;} public bool CanCode {get;set;}
    public List<ChildRow> Children {get;set;} public bool HasChildren {get;set;}
    public string Group {get;set;} public bool GroupExpanded {get;set;} public bool ShowRun {get;set;}
    public string Info {get;set;} public bool HasInfo {get;set;} public string Warning {get;set;} public bool HasWarning {get;set;}
    public string Url {get;set;} public bool HasUrl {get;set;} public bool IsHiddenRow {get;set;}
  }
  public static class Native {
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
    public static void DarkTitleBar(System.IntPtr hwnd) { int on = 1; DwmSetWindowAttribute(hwnd, 20, ref on, 4); }
  }
}
'@
}

# ---------------------------------------------------------------- window

[xml]$xaml = Get-Content -Raw -Path (Join-Path $AppDir 'MainWindow.xaml')
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $win.FindName($name) }
}

$settings = Get-DcSettings
$iconPath = Join-Path $AppDir 'DevControl.ico'
$pngPath  = Join-Path $AppDir 'DevControl.png'
if (Test-Path $iconPath) { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) }
if (Test-Path $pngPath)  { $ui.AppIcon.Source = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$pngPath) }
$ui.ModePill.ToolTip = "Mode in $($settings.wslConfigPath) (applies at next WSL start)"
$win.add_SourceInitialized({ try { [DevControl.Native]::DarkTitleBar((New-Object Windows.Interop.WindowInteropHelper $win).Handle) } catch { } })

$IconContainer = [string][char]0xE7B8   # Segoe MDL2 "package"
$IconTool      = [string][char]0xE90F   # Segoe MDL2 "repair"

# ---------------------------------------------------------------- state

$script:State = @{ Running = $null; Mode = ''; MemoryBytes = 0 }
$script:Busy = $false               # a WSL start/shutdown is in progress
$script:PendingLifecycle = $null    # start/shutdown waiting for in-flight Linux queries to drain
$script:Projects = @()              # from Get-DcProjects (or the cache while WSL is stopped)
$script:ProjectsCached = $false
$script:Containers = @()
$script:Tools = @()                 # background tool pid files (running or exited)
$script:VSCodeCount = 0             # Linux VS Code instances running in WSL (from Get-DcRuntime)
$script:ProjectCfg = @{}            # projects.json "projects"
$script:ConfigMeta = $null          # projects.json top level (groups, collapsed)
$script:GroupExpanded = @{}         # group name -> expanded (what the user last chose; saved in ui-state.json)
$script:ShowHidden = $false         # "Show hidden" toggle (saved in ui-state.json)
$script:LastRows = @()              # rows as last rendered, in display order (source of truth for moves)
$script:Dragging = $false
$script:PromptHook = $null          # self-test replaces the text prompt
$script:UiStatePath = Join-Path $DcDataDir 'ui-state.json'
$script:ProjectOps = @{}            # project name -> current step text
$script:ChildOps = @{}              # child tag -> 'stopping'
$script:Seq = $null                 # running Run/Stop/Restart sequence
$script:ConfirmHook = $null         # self-test replaces the dialogs
$script:Exiting = $false
$script:Jobs = New-Object System.Collections.ArrayList
$script:Tray = $null
$script:TrayItems = @{}
$script:TestLog = New-Object System.Collections.ArrayList

$script:Pool = [runspacefactory]::CreateRunspacePool(1, 6)
$script:Pool.Open()

function Log([string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    if ($ui.LogBox.Text.Length -gt 60000) { $ui.LogBox.Text = $ui.LogBox.Text.Substring(30000) }
    $ui.LogBox.AppendText($line + "`r`n")
    $ui.LogBox.ScrollToEnd()
    Write-DcLog $Message
    [void]$script:TestLog.Add($line)
}

$script:BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$Hex) { $script:BrushConv.ConvertFromString($Hex) }

# Yes/No dialog -> bool
function Confirm-Dc([string]$Message, [string]$Title) {
    if ($script:ConfirmHook) { return [bool](& $script:ConfirmHook $Message $Title 'yesno') }
    return ((Show-DcMessage $Message $Title 'YesNo') -eq 'Yes')
}

# Yes/No/Cancel dialog -> 'Yes' | 'No' | 'Cancel'
function Ask-Dc3([string]$Message, [string]$Title) {
    if ($script:ConfirmHook) { return [string](& $script:ConfirmHook $Message $Title 'yesnocancel') }
    return [string](Show-DcMessage $Message $Title 'YesNoCancel')
}

function Show-DcMessage([string]$Message, [string]$Title, [string]$Buttons) {
    $default = if ($Buttons -eq 'YesNo') { 'No' } else { 'Cancel' }
    if ($win.IsVisible) { [Windows.MessageBox]::Show($win, $Message, "Dev Control - $Title", $Buttons, 'Warning', $default) }
    else { [Windows.MessageBox]::Show($Message, "Dev Control - $Title", $Buttons, 'Warning', $default) }
}

# ---------------------------------------------------------------- background jobs
# Work runs in a runspace pool (Core.ps1 dot-sourced) so the UI never blocks on wsl.exe.
# Done is called on the UI thread as: & $Done <results> <exception-or-null> <context>.
# Kind: 'poll' (Windows-only), 'data' (Linux query), 'action' (user action).

function Start-Bg([string]$Name, [string]$Kind, [scriptblock]$Work, [object[]]$ArgList = @(), [scriptblock]$Done, $Context) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    $text = ". '" + $CorePath.Replace("'", "''") + "'`n`$ErrorActionPreference = 'Stop'`n& {`n" + $Work.ToString() + "`n} @args"
    [void]$ps.AddScript($text)
    foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    $job = [pscustomobject]@{ Name = $Name; Kind = $Kind; PS = $ps; Handle = $ps.BeginInvoke(); Done = $Done; Context = $Context; Started = Get-Date; Warned = $false }
    [void]$script:Jobs.Add($job)
}

function Test-Job([string]$Name) { @($script:Jobs | Where-Object { $_.Name -eq $Name }).Count -gt 0 }
function Get-JobCount([string]$Kind) { @($script:Jobs | Where-Object { $_.Kind -eq $Kind }).Count }

function On-Tick {
    for ($i = $script:Jobs.Count - 1; $i -ge 0; $i--) {
        $j = $script:Jobs[$i]
        if (-not $j.Handle.IsCompleted) {
            if ($j.Kind -ne 'action' -and -not $j.Warned -and ((Get-Date) - $j.Started).TotalSeconds -gt 30) {
                $j.Warned = $true; Log "Slow background query '$($j.Name)' still running after 30s."
            }
            continue
        }
        $script:Jobs.RemoveAt($i)
        $result = $null; $err = $null
        try { $result = $j.PS.EndInvoke($j.Handle) }
        catch { $err = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception } }
        if (-not $err -and $j.PS.Streams.Error.Count -gt 0) { $err = $j.PS.Streams.Error[0].Exception }
        $j.PS.Dispose()
        if ($j.Done) {
            try { & $j.Done @($result) $err $j.Context }
            catch { Log "Internal error handling '$($j.Name)': $($_.Exception.Message)" }
        }
    }
    if ($script:ShowEvent.WaitOne(0)) { Show-Main }
    # A start/shutdown must not overlap a Linux query: a query that passed its
    # "is WSL running?" check just before --shutdown would boot WSL straight back up.
    if ($script:PendingLifecycle -and (Get-JobCount 'data') -eq 0) {
        $p = $script:PendingLifecycle
        $script:PendingLifecycle = $null
        Invoke-Lifecycle $p
    }
}

# ---------------------------------------------------------------- status

function Start-StatusPoll {
    if (Test-Job 'status') { return }
    Start-Bg -Name 'status' -Kind 'poll' -Work { Get-DcStatus } -Done {
        param($r, $e)
        if ($e) { Log "Status check failed: $($e.Message)"; return }
        Set-Status $r[0]
    }
}

function Set-Status($st) {
    $was = $script:State.Running
    $script:State.Running = [bool]$st.Running
    $script:State.Mode = $st.Mode
    $script:State.MemoryBytes = $st.MemoryBytes

    if ($st.Running) {
        $ui.WslDot.Fill = Get-Brush '#22C55E'; $ui.WslText.Text = 'WSL: Running'
        $ui.MemText.Text = "Memory: $(Format-DcBytes $st.MemoryBytes)"
    } else {
        $ui.WslDot.Fill = Get-Brush '#6B7280'; $ui.WslText.Text = 'WSL: Stopped'
        $ui.MemText.Text = 'Memory: -'
    }
    if ($script:Busy) { $ui.WslDot.Fill = Get-Brush '#F59E0B' }
    $detail = @($st.ModeMemory, $(if ($st.ModeProcessors) { "$($st.ModeProcessors) CPU" })) | Where-Object { $_ }
    $ui.ModeText.Text = "Mode: $($st.Mode)" + $(if ($detail) { " ($($detail -join ' / '))" } else { '' })

    if ($null -eq $ui.ModeCombo.SelectedItem -and $ui.ModeCombo.Items -contains $st.Mode) { $ui.ModeCombo.SelectedItem = $st.Mode }
    if ($script:Tray) {
        $t = "Dev Control - WSL " + $(if ($st.Running) { "running, $(Format-DcBytes $st.MemoryBytes)" } else { 'stopped' })
        $script:Tray.Text = $t.Substring(0, [Math]::Min(63, $t.Length))
    }

    if ($st.Running -and $was -ne $true) {
        if ($null -ne $was) { Log 'WSL is running.' }
        Update-Projects; Update-Runtime; Update-LinuxInfo
    } elseif (-not $st.Running -and $was -ne $false) {
        if ($null -ne $was) { Log 'WSL: Stopped.' }
        $script:Containers = @(); $script:Tools = @(); $script:VSCodeCount = 0
        $ui.LiveText.Text = 'Live: -'
        if ($script:Projects.Count -eq 0) { $script:Projects = @(Get-DcProjectCache) }
        $script:ProjectsCached = $true
    }
    Update-Enablement
}

function Update-LinuxInfo {
    if (-not $script:State.Running -or $script:Busy -or (Test-Job 'linuxinfo')) { return }
    Start-Bg -Name 'linuxinfo' -Kind 'data' -Work { Get-DcLinuxInfo } -Done {
        param($r, $e)
        if ($e -or -not $r) { return }
        $ui.LiveText.Text = "Live: $($r[0].Cpus) CPU / $(Format-DcBytes $r[0].MemBytes)"
    }
}

# ---------------------------------------------------------------- project config (projects.json)

function Get-Cfg([string]$Name) { $script:ProjectCfg[$Name] }
function Get-CfgValue($Cfg, [string]$Key, $Default) {
    if ($Cfg -and $Cfg.PSObject.Properties[$Key] -and $null -ne $Cfg.$Key) { $Cfg.$Key } else { $Default }
}
function Test-Pinned([string]$Name) { [bool](Get-CfgValue (Get-Cfg $Name) 'pinned' $false) }

# Per-user view state (expanded groups, show hidden) - survives restarts, separate from projects.json.
function Import-UiState {
    try {
        if (Test-Path $script:UiStatePath) {
            $j = Get-Content -Raw -Path $script:UiStatePath | ConvertFrom-Json
            if ($j.expanded) { foreach ($p in $j.expanded.PSObject.Properties) { $script:GroupExpanded[$p.Name] = [bool]$p.Value } }
            $script:ShowHidden = [bool]$j.showHidden
        }
    } catch { Log "ui-state.json ignored: $($_.Exception.Message)" }
}

function Save-UiState {
    try {
        $state = [ordered]@{ expanded = $script:GroupExpanded; showHidden = $script:ShowHidden }
        [IO.File]::WriteAllText($script:UiStatePath, (ConvertTo-DcJson $state), (New-Object Text.UTF8Encoding $false))
    } catch { Log "Could not save ui-state.json: $($_.Exception.Message)" }
}

function Import-Config([switch]$Quiet) {
    try {
        $script:ProjectCfg = Get-DcProjectConfig
        $script:ConfigMeta = Get-DcConfigFile
        $ui.PinnedHint.Text = ''
        if (-not $Quiet) { Log "Loaded projects.json ($($script:ProjectCfg.Count) configured project(s))." }
    } catch {
        $script:ProjectCfg = @{}
        $ui.PinnedHint.Text = 'projects.json has an error - see log.'
        Log "projects.json could not be read: $($_.Exception.Message)"
    }
    Update-TrayRunMenu
    Update-Enablement
}

# ---------------------------------------------------------------- rendering

function Get-Idle { -not $script:Busy -and -not $script:PendingLifecycle }

function Update-Enablement {
    $run  = $script:State.Running -eq $true
    $idle = Get-Idle
    $free = $idle -and -not $script:Seq
    $ui.StartBtn.IsEnabled = $free
    $ui.StopWslBtn.IsEnabled = $free -and $run
    $ui.RefreshBtn.IsEnabled = $idle -and $run
    $ui.StopAllBtn.IsEnabled = $idle -and $run -and $script:Containers.Count -gt 0
    $ui.CodeOpenBtn.IsEnabled = $free
    $ui.CodeQuitBtn.IsEnabled = $free -and $run -and $script:VSCodeCount -gt 0
    $ui.CodeText.Text = if (-not $run) { 'WSL is stopped, so VS Code is not running in it.' }
        elseif ($script:VSCodeCount -gt 0) { "Running in WSL: $($script:VSCodeCount) instance(s)." }
        else { 'Not running in WSL.' }
    if ($script:TrayItems.Stop) { $script:TrayItems.Stop.Enabled = $free -and $run }
    if ($script:TrayItems.Start) { $script:TrayItems.Start.Enabled = $free }
    if ($script:TrayItems.Run) { $script:TrayItems.Run.Enabled = $free }
    if ($script:TrayItems.CodeOpen) { $script:TrayItems.CodeOpen.Enabled = $free }
    if ($script:TrayItems.CodeQuit) { $script:TrayItems.CodeQuit.Enabled = $free -and $run -and $script:VSCodeCount -gt 0 }
    Show-Projects
}

function New-ChildRow([string]$Icon, [string]$Name, [string]$Detail, [string]$Cpu, [string]$Mem, [string]$Tag, [string]$Color, [bool]$HasAction) {
    $c = New-Object DevControl.ChildRow
    $c.Icon = $Icon; $c.Name = $Name; $c.Detail = $Detail; $c.Cpu = $Cpu; $c.Mem = $Mem; $c.Tag = $Tag
    $c.StatusColor = $Color; $c.HasAction = $HasAction
    $c.CanAct = $HasAction -and $script:State.Running -eq $true -and (Get-Idle) -and -not $script:ChildOps[$Tag]
    if ($script:ChildOps[$Tag]) { $c.Detail = "stopping...  |  $Detail" }
    $c
}

function New-ContainerChild($c) {
    $mem = if ($c.MemPerc -and $c.MemPerc -ne '-') { "$($c.Mem) ($($c.MemPerc))" } else { $c.Mem }
    $label = if ($c.Service) { $c.Service } else { $c.Name }
    New-ChildRow $IconContainer $label "$($c.Name)  |  $($c.Image)  |  $($c.Status)" $c.Cpu $mem "c:$($c.Id)" '#22C55E' $true
}

function New-ToolChild($t, [string]$ProjectName) {
    $display = $t.Tool
    foreach ($ct in @(Get-CfgValue (Get-Cfg $ProjectName) 'tools' @())) { if ((Get-DcSlug $ct.name) -eq $t.Tool) { $display = $ct.name } }
    if ($t.Running) {
        New-ChildRow $IconTool $display "background tool  |  pid $($t.Pid)" $t.Cpu $t.Mem "t:$($t.Slug)/$($t.Tool)" '#22C55E' $true
    } else {
        New-ChildRow $IconTool $display "exited  |  log: ~/.cache/devcontrol/run/$($t.Slug)/$($t.Tool).log" '-' '-' "t:$($t.Slug)/$($t.Tool)" '#F59E0B' $false
    }
}

# Whether Run/Stop may use docker compose for a project, and why not.
# Worktrees and folders sharing a compose name with another folder are blocked unless
# projects.json says "compose": true for that folder: compose identifies a stack by NAME,
# so `up` there would replace the other folder's containers and reuse its volumes.
function Get-ComposePolicy($p) {
    $cfg = Get-Cfg $p.Name
    $explicit = $cfg -and $cfg.PSObject.Properties['compose']
    if ($explicit -and -not $cfg.compose) { return @{ Allowed = $false; Reason = '' } }
    if (-not $p.Compose) { return @{ Allowed = $false; Reason = '' } }
    if ($explicit) { return @{ Allowed = $true; Reason = '' } }
    if ($p.Worktree) {
        return @{ Allowed = $false; Reason = "Compose disabled: git worktree of $($p.Parent), and its compose name '$($p.ComposeName)' is the main project's." }
    }
    $others = @($script:Projects | Where-Object { $_.Name -ne $p.Name -and $_.Compose -and $_.ComposeName -eq $p.ComposeName } | ForEach-Object { $_.Name })
    if ($others.Count) { return @{ Allowed = $false; Reason = "Compose disabled: compose name '$($p.ComposeName)' is also used by $($others -join ', ')." } }
    @{ Allowed = $true; Reason = '' }
}

function Format-Age([int64]$Epoch) {
    if ($Epoch -le 0) { return '' }
    $d = [int](([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $Epoch) / 86400)
    if ($d -lt 1) { 'today' } elseif ($d -eq 1) { 'yesterday' } elseif ($d -lt 60) { "$d days ago" } else { "$([int]($d / 30)) months ago" }
}

# A folder with no projects.json entry at all has never been classified: it goes to 'New',
# which sits above every other group so a folder added in Documents is noticed.
function Get-GroupName($p) {
    $cfg = Get-Cfg $p.Name
    $g = [string](Get-CfgValue $cfg 'group' '')
    if ($g) { return $g }
    if ($p.PSObject.Properties['Worktree'] -and $p.Worktree) { return "$($p.Parent) worktrees" }
    if (-not $cfg) { return 'New' }
    'Other'
}

function Get-GroupRank([string]$Group) {
    $order = @(Get-CfgValue $script:ConfigMeta 'groups' @())
    $i = [array]::IndexOf($order, $Group)
    if ($i -ge 0) { return $i }
    if ($Group -eq 'New') { return -1 }
    if ($Group -eq 'Other containers') { return 1002 }
    if ($Group -eq 'Other') { return 1001 }
    1000
}

# The user's last choice (ui-state.json) wins over "collapsed" in projects.json.
function Test-GroupExpanded([string]$Group) {
    if ($script:GroupExpanded.ContainsKey($Group)) { return [bool]$script:GroupExpanded[$Group] }
    $collapsed = @(Get-CfgValue $script:ConfigMeta 'collapsed' @())
    -not ($collapsed -contains $Group -or $Group -like '* worktrees')
}

function Get-ProjectRows {
    $run  = $script:State.Running -eq $true
    $idle = Get-Idle
    $root = ([string]$settings.projectsRoot).TrimEnd('/')
    $usedC = @{}; $usedT = @{}
    $rows = New-Object System.Collections.ArrayList
    $visible = @($script:Projects | Where-Object { $script:ShowHidden -or -not (Get-CfgValue (Get-Cfg $_.Name) 'hidden' $false) })
    foreach ($p in $visible) {
        $cfg  = Get-Cfg $p.Name
        $dir  = if ($p.PSObject.Properties['ComposeDir'] -and $p.ComposeDir) { $p.ComposeDir } else { "$root/$($p.Name)" }
        $slug = Get-DcSlug $p.Name
        $policy = Get-ComposePolicy $p
        $tools = @(Get-CfgValue $cfg 'tools' @() | Where-Object { $_ })
        $r = New-Object DevControl.ProjectRow
        $r.Name = $p.Name; $r.IsProject = $true
        $r.Group = Get-GroupName $p; $r.GroupExpanded = Test-GroupExpanded $r.Group
        $r.Mode = [string](Get-CfgValue $cfg 'mode' ''); $r.HasMode = [bool]$r.Mode
        $r.Url = [string](Get-CfgValue $cfg 'url' ''); $r.HasUrl = [bool]$r.Url
        $r.ShowRun = $policy.Allowed -or $tools.Count -gt 0
        $r.Children = New-Object 'System.Collections.Generic.List[DevControl.ChildRow]'
        $cs = @($script:Containers | Where-Object { $_.Dir -eq $dir })
        $ts = @($script:Tools | Where-Object { $_.Slug -eq $slug })
        foreach ($c in $cs) { $usedC[$c.Id] = 1; $r.Children.Add((New-ContainerChild $c)) }
        foreach ($t in $ts) { $usedT["$($t.Slug)/$($t.Tool)"] = 1; $r.Children.Add((New-ToolChild $t $p.Name)) }
        $r.HasChildren = $r.Children.Count -gt 0

        if ($p.PSObject.Properties['Worktree'] -and $p.Worktree) {
            $state = if ($p.Ahead -eq 0) { 'fully merged' } else { "$($p.Ahead) commit(s) not merged" }
            $clean = if ($p.Dirty -eq 0) { 'clean' } else { "$($p.Dirty) uncommitted file(s)" }
            $r.Info = "branch $($p.Branch)  -  $state, $clean" + $(if ($p.Ahead -eq 0 -and $p.Dirty -eq 0) { '  -  safe to remove' } else { '' })
        } elseif ($p.PSObject.Properties['LastActive'] -and $p.LastActive) {
            $r.Info = "last change $(Format-Age $p.LastActive)"
        }
        $r.IsHiddenRow = [bool](Get-CfgValue $cfg 'hidden' $false)
        if ($r.IsHiddenRow) { $r.Info = ("hidden  -  " + $r.Info).TrimEnd(' ', '-') }
        $r.HasInfo = [bool]$r.Info
        $r.Warning = (@([string](Get-CfgValue $cfg 'warning' ''), $policy.Reason) | Where-Object { $_ }) -join '  '
        $r.HasWarning = [bool]$r.Warning

        $nt = @($ts | Where-Object { $_.Running }).Count
        $op = $script:ProjectOps[$p.Name]
        if ($op) { $r.Status = "$op..."; $r.ShortStatus = $r.Status; $r.StatusColor = '#3B82F6' }
        elseif (-not $run) { $r.Status = 'WSL stopped'; $r.ShortStatus = 'WSL stopped'; $r.StatusColor = '#6B7280' }
        elseif ($cs.Count + $nt -gt 0) {
            $parts = @(); if ($cs.Count) { $parts += "$($cs.Count) container(s)" }; if ($nt) { $parts += "$nt tool(s)" }
            $r.ShortStatus = $parts -join ', '; $r.Status = "running  -  $($r.ShortStatus)"; $r.StatusColor = '#22C55E'
        }
        elseif ($p.Compose -and $p.Status -and $p.Status -ne 'down') { $r.Status = $p.Status; $r.ShortStatus = $p.Status; $r.StatusColor = '#F59E0B' }
        else {
            $r.ShortStatus = 'stopped'
            $r.Status = if ($r.ShowRun) { 'stopped' } else { 'editor only' }
            $r.StatusColor = '#6B7280'
        }
        $free = $idle -and -not $script:Seq -and -not $op
        $r.CanRun = $free
        $r.CanAct = $free -and $run
        $r.CanCode = $free
        [void]$rows.Add($r)
    }
    $otherC = @($script:Containers | Where-Object { -not $usedC[$_.Id] })
    $otherT = @($script:Tools | Where-Object { -not $usedT["$($_.Slug)/$($_.Tool)"] })
    if ($otherC.Count + $otherT.Count -gt 0) {
        $r = New-Object DevControl.ProjectRow
        $r.Name = 'Not part of a listed project'; $r.IsProject = $false
        $r.Group = 'Other containers'; $r.GroupExpanded = Test-GroupExpanded $r.Group
        $r.Status = "$($otherC.Count) container(s), $($otherT.Count) tool(s)"; $r.StatusColor = '#9AA0A6'
        $r.Children = New-Object 'System.Collections.Generic.List[DevControl.ChildRow]'
        foreach ($c in $otherC) { $r.Children.Add((New-ContainerChild $c)) }
        foreach ($t in $otherT) { $r.Children.Add((New-ToolChild $t '')) }
        $r.HasChildren = $true
        [void]$rows.Add($r)
    }
    $sorted = New-Object System.Collections.ArrayList
    $orderOf = { param($n) $v = Get-CfgValue (Get-Cfg $n) 'order' $null; if ($null -eq $v) { 100000 } else { [int]$v } }
    foreach ($r in @($rows | Sort-Object @{ Expression = { Get-GroupRank $_.Group } }, Group, @{ Expression = { & $orderOf $_.Name } }, Name)) { [void]$sorted.Add($r) }
    , $sorted
}

function Show-Projects {
    if ($script:Dragging) { return }   # rebuilding the list mid-drag would pull the item out from under the mouse
    $rows = Get-ProjectRows
    $script:LastRows = @($rows)
    $view = [System.Windows.Data.ListCollectionView]::new($rows)
    $view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'Group'))
    $ui.ProjectList.ItemsSource = $view
    $ui.PinnedList.ItemsSource = @($rows | Where-Object { $_.IsProject -and -not $_.IsHiddenRow -and (Test-Pinned $_.Name) })
    if (-not $ui.PinnedHint.Text.StartsWith('projects.json') -or -not $ui.PinnedHint.Text) {
        $ui.PinnedHint.Text = if (@($ui.PinnedList.ItemsSource).Count -eq 0) { 'No pinned projects. Use a project''s menu to pin it.' } else { '' }
    }
    $run = $script:State.Running -eq $true
    $nc = $script:Containers.Count
    $ui.ProjectsHint.Text = if (-not $settings.projectsRoot) { $DcNoProjectsRoot }
        elseif (-not $run) { 'WSL is stopped. Run starts it in the project''s mode (list is cached).' }
        else { "$nc container(s), $(@($script:Tools | Where-Object { $_.Running }).Count) tool(s) running  -  drag cards to reorder, drop on a group header to move, right-click for more" }
}

# ---------------------------------------------------------------- data refresh (Linux queries)

function Update-Projects {
    if (-not $settings.projectsRoot) { return }   # nothing to list; Show-Projects says why
    if (-not $script:State.Running -or $script:Busy -or $script:PendingLifecycle -or (Test-Job 'projects')) { return }
    Start-Bg -Name 'projects' -Kind 'data' -Work { $p = Get-DcProjects; Save-DcProjectCache $p; $p } -Done {
        param($r, $e)
        if ($e) { if ($script:State.Running) { Log "Project list failed: $($e.Message)" }; return }
        $script:Projects = @($r | Where-Object { $_ }); $script:ProjectsCached = $false
        Show-Projects
    }
}

function Update-Runtime {
    if (-not $script:State.Running -or $script:Busy -or $script:PendingLifecycle -or (Test-Job 'runtime')) { return }
    Start-Bg -Name 'runtime' -Kind 'data' -Work { Get-DcRuntime } -Done {
        param($r, $e)
        if ($e) { if ($script:State.Running) { Log "Container/tool status failed: $($e.Message)" }; return }
        $script:Containers = @($r[0].Containers | Where-Object { $_ })
        $script:Tools = @($r[0].Tools | Where-Object { $_ })
        $script:VSCodeCount = [int]$r[0].VSCode
        $live = @($script:Containers | ForEach-Object { "c:$($_.Id)" }) + @($script:Tools | Where-Object { $_.Running } | ForEach-Object { "t:$($_.Slug)/$($_.Tool)" })
        foreach ($k in @($script:ChildOps.Keys)) { if ($live -notcontains $k) { $script:ChildOps.Remove($k) } }
        Update-Enablement
    }
}

# ---------------------------------------------------------------- WSL lifecycle

# $Then (optional) is called with $true/$false when the flow finishes or is cancelled.
# $ForProject: called from a project Run - offers "run in the current mode" instead of restarting.
# No $Mode = start with whatever is in .wslconfig (the Start button works without picking a mode).
function Start-WslFlow([string]$Mode, [scriptblock]$Then, [string]$ForProject) {
    if ($script:Busy -or $script:PendingLifecycle) { Log 'A WSL start/shutdown is already in progress.'; if ($Then) { & $Then $false }; return }
    $restart = $false
    if ($script:State.Running) {
        if (-not $Mode -or $Mode -eq $script:State.Mode) {
            if (-not $ForProject) { Log $(if ($Mode) { "WSL is already running in $Mode mode." } else { 'WSL is already running.' }) }
            if ($Then) { & $Then $true }
            return
        }
        $cur = $script:State.Mode
        if ($ForProject) {
            $msg = "$ForProject runs in '$Mode' mode, but WSL is running in '$cur' mode.`n`n" +
                   "Yes  -  restart WSL in '$Mode' (all containers stop, terminals disconnect, VS Code windows close - save first)`n" +
                   "No  -  run it now in '$cur' mode`nCancel  -  don't run"
            $a = Ask-Dc3 $msg 'Switch mode'
            if ($a -eq 'No') { Log "Running $ForProject in the current '$cur' mode."; if ($Then) { & $Then $true }; return }
            if ($a -ne 'Yes') { Log "Cancelled."; if ($Then) { & $Then $false }; return }
        } else {
            $msg = "WSL is running in '$cur' mode. Switching to '$Mode' needs a restart:`n`n" +
                   "  - all running containers stop`n  - terminals disconnect and VS Code windows close (save your work first)`n`n" +
                   "Shut down WSL and start it again in '$Mode' mode?"
            if (-not (Confirm-Dc $msg 'Switch mode')) { Log "Cancelled switching to $Mode mode."; if ($Then) { & $Then $false }; return }
        }
        $restart = $true
    }
    Log $(if ($restart) { "Restarting WSL in $Mode mode..." } elseif ($Mode) { "Starting WSL in $Mode mode..." } else { 'Starting WSL (current .wslconfig)...' })
    $script:Busy = $true
    $script:PendingLifecycle = @{ Type = 'start'; Mode = $Mode; Restart = $restart; Then = $Then }
    Update-Enablement
}

function Stop-WslFlow([scriptblock]$Then) {
    if ($script:Busy -or $script:PendingLifecycle -or $script:Seq) { Log 'Busy - wait for the current operation to finish.'; if ($Then) { & $Then $false }; return }
    if (-not $script:State.Running) { Log 'WSL is already stopped.'; if ($Then) { & $Then $true }; return }
    $n = $script:Containers.Count
    $nt = @($script:Tools | Where-Object { $_.Running }).Count
    $msg = "Stop WSL and free its memory and CPU?`n`nThis runs wsl --shutdown:`n" +
           "  - $n running container(s) and $nt tool(s) stop`n  - terminals disconnect and VS Code windows close (save your work first)"
    if (-not (Confirm-Dc $msg 'Stop WSL')) { Log 'Stop WSL cancelled.'; if ($Then) { & $Then $false }; return }
    Log 'Shutting down WSL...'
    $script:Busy = $true
    $script:PendingLifecycle = @{ Type = 'shutdown'; Then = $Then }
    Update-Enablement
}

function Invoke-Lifecycle($p) {
    if ($p.Type -eq 'shutdown') {
        $work = { Stop-DcWsl }; $argList = @()
    } else {
        $work = {
            param($mode, $restart)
            $out = @()
            if ($mode) { Set-DcMode $mode; $out += "Mode set to $mode." }
            if ($restart) { $out += Stop-DcWsl; Start-Sleep -Seconds 2 }
            $out += Start-DcWslBoot
            $out -join ' '
        }
        $argList = @($p.Mode, $p.Restart)
    }
    Start-Bg -Name 'lifecycle' -Kind 'action' -Work $work -ArgList $argList -Context $p -Done {
        param($r, $e, $c)
        $script:Busy = $false
        if ($e) { Log "FAILED: $($e.Message)" } else { Log ($r -join ' ') }
        $script:State.Running = $null   # force a fresh transition so lists reload
        Start-StatusPoll
        Update-Enablement
        if ($c.Then) { & $c.Then (-not $e) }
    }
}

# ---------------------------------------------------------------- project Run / Stop / Restart

function Get-SequenceSteps([string]$Kind, [string]$Name) {
    $p = $script:Projects | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    $cfg = Get-Cfg $Name
    $compose = $p -and (Get-ComposePolicy $p).Allowed
    $sub = [string](Get-CfgValue $cfg 'composeDir' '')
    $services = @(Get-CfgValue $cfg 'services' @() | Where-Object { $_ })
    $tools = @(Get-CfgValue $cfg 'tools' @() | Where-Object { $_ })
    $mode = [string](Get-CfgValue $cfg 'mode' '')
    $steps = @()
    switch ($Kind) {
        'run' {
            $steps += @{ Type = 'wsl'; Mode = $mode; Text = 'starting WSL' }
            if ($compose) { $steps += @{ Type = 'compose'; Op = 'up'; Sub = $sub; Services = $services; Text = 'compose up' } }
            foreach ($t in $tools) { $steps += @{ Type = 'tool'; Tool = $t; Text = "tool: $($t.name)" } }
            if (Get-CfgValue $cfg 'openVSCode' $true) { $steps += @{ Type = 'code'; Text = 'opening VS Code' } }
        }
        'code' {
            if (-not $script:State.Running) { $steps += @{ Type = 'wsl'; Mode = $mode; Text = 'starting WSL' } }
            $steps += @{ Type = 'code'; Text = 'opening VS Code' }
        }
        'stop' {
            $steps += @{ Type = 'stopTools'; Text = 'stopping tools' }
            foreach ($t in @($tools | Where-Object { $_.PSObject.Properties['stop'] -and $_.stop })) { $steps += @{ Type = 'toolStop'; Tool = $t; Text = "stop: $($t.name)" } }
            if ($compose) { $steps += @{ Type = 'compose'; Op = 'down'; Sub = $sub; Services = @(); Text = 'compose down' } }
        }
        'restart' {
            $steps += @{ Type = 'stopTools'; Text = 'stopping tools' }
            if ($compose) { $steps += @{ Type = 'compose'; Op = 'restart'; Sub = $sub; Services = $services; Text = 'compose restart' } }
            foreach ($t in @($tools | Where-Object { $_.background })) { $steps += @{ Type = 'tool'; Tool = $t; Text = "tool: $($t.name)" } }
        }
    }
    , $steps
}

function Start-Sequence([string]$Kind, [string]$Name) {
    if ($script:Seq) { Log "Busy: '$($script:Seq.Label)' is still running."; return }
    if ($script:Busy -or $script:PendingLifecycle) { Log 'A WSL start/shutdown is in progress.'; return }
    if ($Kind -notin @('run', 'code') -and -not $script:State.Running) { Log "WSL is stopped - nothing to $Kind."; return }
    $steps = Get-SequenceSteps $Kind $Name
    $script:Seq = @{ Label = "$Kind $Name"; Name = $Name; Steps = $steps; Index = 0 }
    Log "== $Kind $Name ($(@($steps | ForEach-Object { $_.Text }) -join ' > '))"
    Invoke-NextStep
}

$script:StepDone = {
    param($ok)
    if (-not $script:Seq) { return }
    if ($ok) { Invoke-NextStep }
    else { Log "== $($script:Seq.Label): stopped at step $($script:Seq.Index) of $($script:Seq.Steps.Count)."; Complete-Sequence }
}

function Complete-Sequence {
    if ($script:Seq) { $script:ProjectOps.Remove($script:Seq.Name) }
    $script:Seq = $null
    Update-Projects; Update-Runtime
    Update-Enablement
}

function Invoke-NextStep {
    $q = $script:Seq
    if (-not $q) { return }
    if ($q.Index -ge $q.Steps.Count) { Log "== $($q.Label): done."; Complete-Sequence; return }
    $st = $q.Steps[$q.Index]
    $q.Index++
    $script:ProjectOps[$q.Name] = $st.Text
    Update-Enablement
    switch ($st.Type) {
        'wsl'       { Start-WslFlow $st.Mode $script:StepDone $q.Name }
        'compose'   { Invoke-ComposeStep $q.Name $st.Op $st.Sub $st.Services }
        'toolStop'  { Invoke-ToolStopStep $q.Name $st.Tool }
        'tool'      { Invoke-ToolStep $q.Name $st.Tool }
        'stopTools' { Invoke-StopTools (Get-DcSlug $q.Name) '' $script:StepDone }
        'code'      { Open-Code $q.Name $script:StepDone }
    }
}

function Invoke-ComposeStep([string]$Name, [string]$Op, [string]$Sub, [string[]]$Services) {
    Log ("docker compose $Op - $Name" + $(if ($Services) { " ($($Services -join ', '))" } else { '' }) + ' ...')
    Start-Bg -Name "compose:$Name" -Kind 'action' -Work { param($n, $a, $d, $sv) Invoke-DcCompose $n $a $d $sv } -ArgList @($Name, $Op, $Sub, $Services) -Context @{ Name = $Name; Op = $Op } -Done {
        param($r, $e, $c)
        if ($e) { Log "FAILED: $($e.Message)" }
        else {
            $last = @(($r -join "`n") -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3
            Log "compose $($c.Op) $($c.Name): done. $($last -join ' / ')"
        }
        Update-Runtime
        & $script:StepDone (-not $e)
    }
}

function Invoke-ToolStep([string]$Name, $Tool) {
    Log "tool '$($Tool.name)' ($(if ($Tool.background) { 'background' } else { 'run once' })) - $Name ..."
    Start-Bg -Name "tool:$Name" -Kind 'action' -Work { param($n, $t) Invoke-DcTool $n $t } -ArgList @($Name, $Tool) -Context @{ Tool = $Tool } -Done {
        param($r, $e, $c)
        if ($e) { Log "FAILED: $($e.Message)" } else { Log "tool '$($c.Tool.name)': $((($r -join "`n") -split "`n" | Where-Object { $_ }) -join ' / ')" }
        Update-Runtime
        & $script:StepDone (-not $e)
    }
}

function Invoke-ToolStopStep([string]$Name, $Tool) {
    Start-Bg -Name "toolstop:$Name" -Kind 'action' -Work { param($n, $t) Invoke-DcToolStop $n $t } -ArgList @($Name, $Tool) -Done {
        param($r, $e)
        if ($e) { Log "FAILED: $($e.Message)" } else { Log ($r -join ' ') }
        & $script:StepDone (-not $e)
    }
}

function Invoke-StopTools([string]$Slug, [string]$ToolSlug, [scriptblock]$Then) {
    Start-Bg -Name "stoptools:$Slug" -Kind 'action' -Work { param($s, $t) Stop-DcTools $s $t } -ArgList @($Slug, $ToolSlug) -Context @{ Then = $Then } -Done {
        param($r, $e, $c)
        if ($e) { Log "FAILED: $($e.Message)" } else { Log "Tools: $($r -join ' ')" }
        Update-Runtime
        if ($c.Then) { & $c.Then (-not $e) }
    }
}

# An empty $Name opens a window with no folder loaded.
function Open-Code([string]$Name, [scriptblock]$Then) {
    Log $(if ($Name) { "Opening $Name in VS Code..." } else { 'Opening an empty VS Code window...' })
    Start-Bg -Name "code:$Name" -Kind 'action' -Work { param($n) Open-DcVSCode $n } -ArgList @($Name) -Context @{ Then = $Then } -Done {
        param($r, $e, $c)
        if ($e) { Log "VS Code failed: $($e.Message)" } else { Log ($r -join ' ') }
        Update-Runtime
        if ($c.Then) { & $c.Then (-not $e) }
    }
}

# VS Code with no folder. Both flavors run in / connect to Linux, so WSL has to be up first.
function Open-EmptyCode {
    if ($script:Seq -or $script:Busy -or $script:PendingLifecycle) { Log 'Busy - wait for the current operation to finish.'; return }
    if ($script:State.Running) { Open-Code '' $null; return }
    Start-WslFlow '' { param($ok) if ($ok) { Open-Code '' $null } }
}

# Quits VS Code inside WSL. Containers, background tools and WSL itself keep running.
function Stop-VSCodeFlow {
    if ($script:Seq -or $script:Busy -or $script:PendingLifecycle) { Log 'Busy - wait for the current operation to finish.'; return }
    if (-not $script:State.Running) { Log 'WSL is stopped - VS Code is not running in it.'; return }
    $msg = "Quit VS Code inside WSL?`n`n" +
           "  - every VS Code window closes (hot exit restores unsaved editors, but save first)`n" +
           "  - terminals, Claude Code sessions and extensions running in those windows stop`n`n" +
           "WSL, containers and background tools keep running."
    if (-not (Confirm-Dc $msg 'Quit VS Code')) { Log 'Quit VS Code cancelled.'; return }
    Log 'Quitting VS Code in WSL...'
    Start-Bg -Name 'quitcode' -Kind 'action' -Work { Stop-DcVSCode } -Done {
        param($r, $e)
        if ($e) { Log "FAILED: $($e.Message)" } else { Log ($r -join ' ') }
        Update-Runtime
        Update-Enablement
    }
}

# ---------------------------------------------------------------- single container / tool / stop all

function Stop-Child([string]$Tag) {
    $script:ChildOps[$Tag] = 'stopping'
    Show-Projects
    if ($Tag.StartsWith('c:')) {
        $id = $Tag.Substring(2)
        $c = $script:Containers | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        Log "Stopping container $($c.Name)..."
        Start-Bg -Name "stop:$id" -Kind 'action' -Work { param($i) Stop-DcContainer $i } -ArgList @($id) -Context @{ Tag = $Tag; Name = $c.Name } -Done {
            param($r, $e, $c)
            if ($e) { Log "FAILED: $($e.Message)"; $script:ChildOps.Remove($c.Tag) } else { Log "Stopped $($c.Name)." }
            Update-Runtime; Update-Projects
        }
    } elseif ($Tag.StartsWith('t:')) {
        $slug, $tool = $Tag.Substring(2).Split('/')
        Log "Stopping tool $tool ($slug)..."
        Invoke-StopTools $slug $tool $null
    }
}

function Stop-AllContainersFlow {
    if (-not $script:State.Running) { return }
    if (-not (Confirm-Dc "Stop all $($script:Containers.Count) running container(s)?" 'Stop all containers')) { Log 'Stop all cancelled.'; return }
    foreach ($c in $script:Containers) { $script:ChildOps["c:$($c.Id)"] = 'stopping' }
    Show-Projects
    Log 'Stopping all containers...'
    Start-Bg -Name 'stopall' -Kind 'action' -Work { Stop-DcAllContainers } -Done {
        param($r, $e)
        if ($e) { Log "FAILED: $($e.Message)" } else { Log ($r -join ' ') }
        $script:ChildOps.Clear()
        Update-Runtime; Update-Projects
    }
}

# ---------------------------------------------------------------- arranging projects (order, groups, pin, hide)
# Every change re-reads projects.json from disk, edits it, and writes it back (so edits made in
# Notepad meanwhile are kept), then reloads. Order and groups therefore persist across restarts.

function Get-CfgEntry($Config, [string]$Name) {
    if (-not $Config.PSObject.Properties['projects'] -or $null -eq $Config.projects) {
        $Config | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $Config.projects.PSObject.Properties[$Name]) {
        $Config.projects | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{})
    }
    $Config.projects.$Name
}
function Set-CfgProp($Obj, [string]$Key, $Value) { $Obj | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force }
function Remove-CfgProp($Obj, [string]$Key) { if ($Obj.PSObject.Properties[$Key]) { $Obj.PSObject.Properties.Remove($Key) } }

# Runs $Change against a fresh copy of projects.json, saves it and refreshes the UI.
function Edit-Config([string]$What, [scriptblock]$Change) {
    try {
        $dcConfig = Get-DcConfigFile
        & $Change $dcConfig
        Save-DcConfigFile $dcConfig
        Import-Config -Quiet
        Log $What
    } catch { Log "Could not save projects.json ($What): $($_.Exception.Message)" }
}

function Get-DisplayGroups { @($script:LastRows | Where-Object { $_.IsProject } | ForEach-Object { $_.Group } | Select-Object -Unique) }
function Get-GroupMembers([string]$Group) { @($script:LastRows | Where-Object { $_.IsProject -and $_.Group -eq $Group } | ForEach-Object { $_.Name }) }
function Get-RowByName([string]$Name) { $script:LastRows | Where-Object { $_.IsProject -and $_.Name -eq $Name } | Select-Object -First 1 }

# Puts $Name into $Group just before $Before ('' = at the end) and renumbers that group's order.
function Move-ProjectTo([string]$Name, [string]$Group, [string]$Before = '') {
    $Group = $Group.Trim()
    if (-not $Group) { return }
    $members = New-Object System.Collections.ArrayList
    foreach ($m in (Get-GroupMembers $Group)) { if ($m -ne $Name) { [void]$members.Add($m) } }
    $idx = if ($Before) { $members.IndexOf($Before) } else { -1 }
    if ($idx -lt 0) { $idx = $members.Count }
    $members.Insert($idx, $Name)
    $from = (Get-RowByName $Name).Group
    $displayGroups = Get-DisplayGroups
    Edit-Config $(if ($from -eq $Group) { "Moved $Name within $Group." } else { "Moved $Name to group '$Group'." }) {
        param($c)
        for ($i = 0; $i -lt $members.Count; $i++) { Set-CfgProp (Get-CfgEntry $c $members[$i]) 'order' $i }
        Set-CfgProp (Get-CfgEntry $c $Name) 'group' $Group
        $groups = @(Get-CfgValue $c 'groups' @())
        if ($groups -notcontains $Group) {
            # new group: place it right after the group the project came from
            $full = New-Object System.Collections.ArrayList
            foreach ($g in @($groups + $displayGroups | Select-Object -Unique)) { [void]$full.Add($g) }
            $at = $full.IndexOf($from)
            if ($at -lt 0) { [void]$full.Add($Group) } else { $full.Insert($at + 1, $Group) }
            Set-CfgProp $c 'groups' @($full)
        }
    }
}

function Move-ProjectStep([string]$Name, [int]$Delta) {
    $row = Get-RowByName $Name
    $members = Get-GroupMembers $row.Group
    $i = [array]::IndexOf($members, $Name)
    $j = $i + $Delta
    if ($j -lt 0 -or $j -ge $members.Count) { return }
    $before = if ($Delta -lt 0) { $members[$j] } elseif ($j + 1 -lt $members.Count) { $members[$j + 1] } else { '' }
    Move-ProjectTo $Name $row.Group $before
}

function Move-GroupStep([string]$Group, [int]$Delta) {
    $order = New-Object System.Collections.ArrayList
    foreach ($g in (Get-DisplayGroups)) { [void]$order.Add($g) }
    $i = $order.IndexOf($Group); $j = $i + $Delta
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $order.Count) { return }
    $order.RemoveAt($i); $order.Insert($j, $Group)
    $extra = @(Get-CfgValue $script:ConfigMeta 'groups' @() | Where-Object { $order -notcontains $_ })   # groups with no visible projects
    Edit-Config "Moved group '$Group' $(if ($Delta -lt 0) { 'up' } else { 'down' })." { param($c) Set-CfgProp $c 'groups' @(@($order) + $extra) }
}

function Rename-Group([string]$Old, [string]$New) {
    $New = $New.Trim()
    if (-not $New -or $New -eq $Old) { return }
    # every project in the group, including hidden ones and auto-grouped (worktree / Other) ones
    $members = @($script:Projects | Where-Object { (Get-GroupName $_) -eq $Old } | ForEach-Object { $_.Name })
    $displayGroups = Get-DisplayGroups
    Edit-Config "Renamed group '$Old' to '$New'." {
        param($c)
        foreach ($m in $members) { Set-CfgProp (Get-CfgEntry $c $m) 'group' $New }
        $groups = @(@(Get-CfgValue $c 'groups' @()) + $displayGroups | Select-Object -Unique | ForEach-Object { if ($_ -eq $Old) { $New } else { $_ } } | Select-Object -Unique)
        Set-CfgProp $c 'groups' $groups
        $col = @(Get-CfgValue $c 'collapsed' @() | ForEach-Object { if ($_ -eq $Old) { $New } else { $_ } } | Select-Object -Unique)
        Set-CfgProp $c 'collapsed' $col
    }
    if ($script:GroupExpanded.ContainsKey($Old)) { $script:GroupExpanded[$New] = $script:GroupExpanded[$Old]; $script:GroupExpanded.Remove($Old); Save-UiState }
}

function Remove-Group([string]$Group) {
    $members = @($script:Projects | Where-Object { (Get-GroupName $_) -eq $Group } | ForEach-Object { $_.Name })
    Edit-Config "Ungrouped '$Group' ($($members.Count) project(s) back to their default group)." {
        param($c)
        foreach ($m in $members) { $e = Get-CfgEntry $c $m; Remove-CfgProp $e 'group'; Remove-CfgProp $e 'order' }
        Set-CfgProp $c 'groups' @(Get-CfgValue $c 'groups' @() | Where-Object { $_ -ne $Group })
        Set-CfgProp $c 'collapsed' @(Get-CfgValue $c 'collapsed' @() | Where-Object { $_ -ne $Group })
    }
}

function Set-ProjectFlag([string]$Name, [string]$Flag, [bool]$On) {
    Edit-Config "$(if ($On) { 'Set' } else { 'Cleared' }) '$Flag' for $Name." {
        param($c)
        $e = Get-CfgEntry $c $Name
        if ($On) { Set-CfgProp $e $Flag $true } else { Remove-CfgProp $e $Flag }
    }
}

# Small dark text prompt (WPF has no InputBox). Returns the text or $null.
function Read-DcText([string]$Title, [string]$Prompt, [string]$Default = '') {
    if ($script:PromptHook) { return (& $script:PromptHook $Title $Prompt $Default) }
    [xml]$px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="380" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="#212329" Foreground="#E6E6E6" FontFamily="Segoe UI" FontSize="13">
  <StackPanel Margin="18">
    <TextBlock x:Name="PromptText" TextWrapping="Wrap" Margin="0,0,0,10"/>
    <TextBox x:Name="Input" Padding="6,5" Background="#17181C" Foreground="#E6E6E6" BorderBrush="#434854" CaretBrush="#E6E6E6"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="OkBtn" Content="OK" IsDefault="True" Style="{DynamicResource BtnPrimary}"/>
      <Button Content="Cancel" IsCancel="True" Style="{DynamicResource Btn}" Margin="0"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $px))
    $w.Resources.MergedDictionaries.Add($win.Resources)
    $w.Title = $Title
    if ($win.IsVisible) { $w.Owner = $win }
    $w.FindName('PromptText').Text = $Prompt
    $in = $w.FindName('Input'); $in.Text = $Default
    $w.FindName('OkBtn').add_Click({ [Windows.Window]::GetWindow($this).DialogResult = $true })
    $w.add_ContentRendered({ $t = $this.FindName('Input'); $t.Focus() | Out-Null; $t.SelectAll() })
    if ($w.ShowDialog()) { $in.Text.Trim() } else { $null }
}

# ---- menus. Items carry their action in Tag (an array) and share one handler: no closures,
# because a closure cannot see this script's functions.
function New-DcMenuItem([string]$Header, $Action, [bool]$Enabled = $true) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $Header; $mi.IsEnabled = $Enabled; $mi.Tag = $Action
    if ($Action) { $mi.add_Click({ param($s, $e) $e.Handled = $true; Invoke-MenuAction $s.Tag }) }
    $mi
}

function Invoke-MenuAction($a) {
    try {
        switch ($a[0]) {
            'up'       { Move-ProjectStep $a[1] -1 }
            'down'     { Move-ProjectStep $a[1] 1 }
            'moveto'   { Move-ProjectTo $a[1] $a[2] }
            'newgroup' {
                $g = Read-DcText 'New group' "New group for '$($a[1])':"
                if ($g) { Move-ProjectTo $a[1] $g }
            }
            'ungroupone' { Edit-Config "Removed $($a[1]) from its group." { param($c) $e = Get-CfgEntry $c $a[1]; Remove-CfgProp $e 'group'; Remove-CfgProp $e 'order' } }
            'pin'      { Set-ProjectFlag $a[1] 'pinned' $true }
            'unpin'    { Set-ProjectFlag $a[1] 'pinned' $false }
            'hide'     { Set-ProjectFlag $a[1] 'hidden' $true }
            'unhide'   { Set-ProjectFlag $a[1] 'hidden' $false }
            'rename'   {
                $n = Read-DcText 'Rename group' "New name for group '$($a[1])':" $a[1]
                if ($n) { Rename-Group $a[1] $n }
            }
            'gup'      { Move-GroupStep $a[1] -1 }
            'gdown'    { Move-GroupStep $a[1] 1 }
            'ungroup'  { Remove-Group $a[1] }
        }
    } catch { Log "Menu action failed: $($_.Exception.Message)" }
}

function New-ProjectMenu([string]$Name) {
    $row = Get-RowByName $Name
    $m = New-Object Windows.Controls.ContextMenu
    if (-not $row) { return $m }
    $members = Get-GroupMembers $row.Group
    $i = [array]::IndexOf($members, $Name)
    [void]$m.Items.Add((New-DcMenuItem 'Move up' @('up', $Name) ($i -gt 0)))
    [void]$m.Items.Add((New-DcMenuItem 'Move down' @('down', $Name) ($i -lt $members.Count - 1)))
    $to = New-DcMenuItem 'Move to group' $null
    foreach ($g in (Get-DisplayGroups)) { if ($g -ne $row.Group) { [void]$to.Items.Add((New-DcMenuItem $g @('moveto', $Name, $g))) } }
    foreach ($g in @(Get-CfgValue $script:ConfigMeta 'groups' @())) {
        if ($g -ne $row.Group -and (Get-DisplayGroups) -notcontains $g) { [void]$to.Items.Add((New-DcMenuItem $g @('moveto', $Name, $g))) }
    }
    [void]$to.Items.Add((New-Object Windows.Controls.Separator))
    [void]$to.Items.Add((New-DcMenuItem 'New group...' @('newgroup', $Name)))
    [void]$m.Items.Add($to)
    if (Get-CfgValue (Get-Cfg $Name) 'group' '') { [void]$m.Items.Add((New-DcMenuItem 'Remove from group' @('ungroupone', $Name))) }
    [void]$m.Items.Add((New-Object Windows.Controls.Separator))
    if (Test-Pinned $Name) { [void]$m.Items.Add((New-DcMenuItem 'Unpin' @('unpin', $Name))) } else { [void]$m.Items.Add((New-DcMenuItem 'Pin' @('pin', $Name))) }
    if ($row.IsHiddenRow) { [void]$m.Items.Add((New-DcMenuItem 'Unhide' @('unhide', $Name))) } else { [void]$m.Items.Add((New-DcMenuItem 'Hide' @('hide', $Name))) }
    $m
}

function New-GroupMenu([string]$Group) {
    $groups = Get-DisplayGroups
    $i = [array]::IndexOf($groups, $Group)
    $m = New-Object Windows.Controls.ContextMenu
    [void]$m.Items.Add((New-DcMenuItem 'Rename group...' @('rename', $Group)))
    [void]$m.Items.Add((New-DcMenuItem 'Move group up' @('gup', $Group) ($i -gt 0)))
    [void]$m.Items.Add((New-DcMenuItem 'Move group down' @('gdown', $Group) ($i -ge 0 -and $i -lt $groups.Count - 1)))
    [void]$m.Items.Add((New-Object Windows.Controls.Separator))
    [void]$m.Items.Add((New-DcMenuItem 'Ungroup (projects go back to their default group)' @('ungroup', $Group)))
    $m
}

function Open-Menu($Menu, $Target) {
    $Menu.PlacementTarget = $Target
    $Menu.Placement = if ($Target -is [Windows.Controls.Button]) { 'Bottom' } else { 'MousePoint' }
    $Menu.IsOpen = $true
    $script:LastMenu = $Menu
}

# ---- drag and drop: drop a card on another card (before/after by half) or on a group header.
function Get-RowContext($el) {
    while ($el) {
        if ($el -is [Windows.FrameworkElement]) {
            $dc = $el.DataContext
            if ($dc -is [DevControl.ProjectRow] -or $dc -is [Windows.Data.CollectionViewGroup]) { return $dc }
        }
        $el = if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
    }
    $null
}
function Get-RowElement($el, $row) {
    while ($el) {
        if ($el -is [Windows.Controls.ContentPresenter] -and $el.Content -eq $row) { return $el }
        $el = if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
    }
    $null
}
function Test-InButton($el) {
    while ($el -and $el -ne $ui.ProjectList) {
        if ($el -is [Windows.Controls.Primitives.ButtonBase] -or $el -is [Windows.Controls.Primitives.ScrollBar]) { return $true }
        $el = if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
    }
    $false
}

# Drop handling, separate from the event so it can be tested.
function Invoke-ProjectDrop([string]$Name, $Target, [bool]$After) {
    if ($Target -is [DevControl.ProjectRow] -and $Target.IsProject) {
        if ($Target.Name -eq $Name) { return }
        $before = $Target.Name
        if ($After) {
            $members = @(Get-GroupMembers $Target.Group | Where-Object { $_ -ne $Name })
            $k = [array]::IndexOf($members, $Target.Name)
            $before = if ($k + 1 -lt $members.Count) { $members[$k + 1] } else { '' }
        }
        Move-ProjectTo $Name $Target.Group $before
    } elseif ($Target -is [Windows.Data.CollectionViewGroup] -and [string]$Target.Name -ne 'Other containers') {
        Move-ProjectTo $Name ([string]$Target.Name) ''
    }
}

$script:DragName = $null
$ui.ProjectList.add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $script:DragName = $null
    if (Test-InButton $e.OriginalSource) { return }
    $ctx = Get-RowContext $e.OriginalSource
    if ($ctx -is [DevControl.ProjectRow] -and $ctx.IsProject) { $script:DragName = $ctx.Name; $script:DragStart = $e.GetPosition($ui.ProjectList) }
})
$ui.ProjectList.add_PreviewMouseMove({
    param($s, $e)
    if (-not $script:DragName -or $e.LeftButton -ne 'Pressed') { return }
    $p = $e.GetPosition($ui.ProjectList)
    if ([Math]::Abs($p.X - $script:DragStart.X) -lt 6 -and [Math]::Abs($p.Y - $script:DragStart.Y) -lt 6) { return }
    $name = $script:DragName
    $script:DragName = $null
    $script:Dragging = $true
    try { [void][Windows.DragDrop]::DoDragDrop($ui.ProjectList, (New-Object Windows.DataObject('DevControlProject', $name)), 'Move') }
    finally { $script:Dragging = $false; Show-Projects }
})
$ui.ProjectList.add_DragOver({
    param($s, $e)
    $e.Effects = if ($e.Data.GetDataPresent('DevControlProject') -and (Get-RowContext $e.OriginalSource)) { 'Move' } else { 'None' }
    $e.Handled = $true
})
$ui.ProjectList.add_Drop({
    param($s, $e)
    $e.Handled = $true
    if (-not $e.Data.GetDataPresent('DevControlProject')) { return }
    $name = [string]$e.Data.GetData('DevControlProject')
    $ctx = Get-RowContext $e.OriginalSource
    $after = $false
    if ($ctx -is [DevControl.ProjectRow]) {
        $el = Get-RowElement $e.OriginalSource $ctx
        if ($el) { $after = $e.GetPosition($el).Y -gt ($el.ActualHeight / 2) }
    }
    $script:Dragging = $false
    Invoke-ProjectDrop $name $ctx $after
})
$ui.ProjectList.add_MouseRightButtonUp({
    param($s, $e)
    $ctx = Get-RowContext $e.OriginalSource
    if ($ctx -is [DevControl.ProjectRow] -and $ctx.IsProject) { Open-Menu (New-ProjectMenu $ctx.Name) $ui.ProjectList; $e.Handled = $true }
    elseif ($ctx -is [Windows.Data.CollectionViewGroup] -and [string]$ctx.Name -ne 'Other containers') { Open-Menu (New-GroupMenu ([string]$ctx.Name)) $ui.ProjectList; $e.Handled = $true }
})
$ui.ShowHiddenBox.add_Click({
    $script:ShowHidden = [bool]$ui.ShowHiddenBox.IsChecked
    Save-UiState
    Show-Projects
})

# ---------------------------------------------------------------- window / tray plumbing

function Show-Main {
    $win.Show()
    if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
    $win.Activate() | Out-Null
    $win.Topmost = $true; $win.Topmost = $false
    Update-Runtime
}

function Exit-App {
    $script:Exiting = $true
    $win.Close()
}

function Update-TrayRunMenu {
    if (-not $script:TrayItems.Run) { return }
    $script:TrayItems.Run.DropDownItems.Clear()
    $pinned = @($script:ProjectCfg.Keys | Where-Object { Test-Pinned $_ } | Sort-Object)
    foreach ($n in $pinned) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $n
        $it.Tag = $n
        $it.add_Click({ param($s, $e) Start-Sequence 'run' ([string]$s.Tag) })
        [void]$script:TrayItems.Run.DropDownItems.Add($it)
    }
    $script:TrayItems.Run.Visible = $pinned.Count -gt 0
}

if ($settings.trayIcon) {
    $trayIcon = if (Test-Path $iconPath) { New-Object System.Drawing.Icon($iconPath, [System.Windows.Forms.SystemInformation]::SmallIconSize) }
                else { [System.Drawing.SystemIcons]::Application }
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = $trayIcon
    $script:Tray.Text = 'Dev Control'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:TrayItems.Open = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Dev Control'
    $script:TrayItems.Open.Font = New-Object System.Drawing.Font($script:TrayItems.Open.Font, [System.Drawing.FontStyle]::Bold)
    $script:TrayItems.Open.add_Click({ Show-Main })
    $script:TrayItems.Run = New-Object System.Windows.Forms.ToolStripMenuItem 'Run project'
    $script:TrayItems.Start = New-Object System.Windows.Forms.ToolStripMenuItem 'Start WSL'
    foreach ($m in Get-DcModes) {
        $sub = New-Object System.Windows.Forms.ToolStripMenuItem "$m mode"
        $sub.Tag = $m
        $sub.add_Click({ param($s, $e) Start-WslFlow ([string]$s.Tag) })
        [void]$script:TrayItems.Start.DropDownItems.Add($sub)
    }
    $script:TrayItems.Stop = New-Object System.Windows.Forms.ToolStripMenuItem 'Stop WSL (free resources)'
    $script:TrayItems.Stop.add_Click({ Stop-WslFlow })
    $script:TrayItems.CodeOpen = New-Object System.Windows.Forms.ToolStripMenuItem 'Open VS Code (no folder)'
    $script:TrayItems.CodeOpen.add_Click({ Open-EmptyCode })
    $script:TrayItems.CodeQuit = New-Object System.Windows.Forms.ToolStripMenuItem 'Quit VS Code in WSL'
    $script:TrayItems.CodeQuit.add_Click({ Stop-VSCodeFlow })
    $script:TrayItems.Exit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $script:TrayItems.Exit.add_Click({ Exit-App })
    [void]$menu.Items.Add($script:TrayItems.Open)
    [void]$menu.Items.Add($script:TrayItems.Run)
    [void]$menu.Items.Add($script:TrayItems.Start)
    [void]$menu.Items.Add($script:TrayItems.Stop)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($script:TrayItems.CodeOpen)
    [void]$menu.Items.Add($script:TrayItems.CodeQuit)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($script:TrayItems.Exit)
    $script:Tray.ContextMenuStrip = $menu
    $script:Tray.add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main } })
    $script:Tray.Visible = $true
}

# ---------------------------------------------------------------- event wiring

$ui.ModeCombo.ItemsSource = @(Get-DcModes)
$ui.StartBtn.add_Click({ Start-WslFlow ([string]$ui.ModeCombo.SelectedItem) })
$ui.StopWslBtn.add_Click({ Stop-WslFlow })
$ui.CodeOpenBtn.add_Click({ Open-EmptyCode })
$ui.CodeQuitBtn.add_Click({ Stop-VSCodeFlow })
$ui.RefreshBtn.add_Click({ Update-Projects; Update-Runtime })
$ui.StopAllBtn.add_Click({ Stop-AllContainersFlow })
$ui.ReloadConfigBtn.add_Click({ Import-Config; Update-Projects })
$ui.EditConfigBtn.add_Click({
    $p = Join-Path $AppDir 'projects.json'
    if (Test-Path $p) { Start-Process notepad.exe -ArgumentList "`"$p`"" } else { Log "projects.json not found in $AppDir" }
})

# Buttons inside item templates: Uid = action, Tag = project name or child tag.
$projectClick = [Windows.RoutedEventHandler]{
    param($s, $e)
    $b = $e.OriginalSource
    if (-not ($b -is [Windows.Controls.Button])) { return }
    $tag = [string]$b.Tag
    switch ($b.Uid) {
        'run'     { Start-Sequence 'run' $tag }
        'stop'    { Start-Sequence 'stop' $tag }
        'restart' { Start-Sequence 'restart' $tag }
        'code'    { Start-Sequence 'code' $tag }
        'open'    {
            $u = [string](Get-CfgValue (Get-Cfg $tag) 'url' '')
            if ($u -match '^https?://') { Start-Process $u; Log "Opened $u" } else { Log "No valid url for $tag" }
        }
        'child'   { Stop-Child $tag }
        'menu'    { Open-Menu (New-ProjectMenu $tag) $b }
        'groupmenu' { Open-Menu (New-GroupMenu $tag) $b }
    }
}
$ui.ProjectList.AddHandler([Windows.Controls.Button]::ClickEvent, $projectClick)
$ui.PinnedList.AddHandler([Windows.Controls.Button]::ClickEvent, $projectClick)
# Remember expanded/collapsed groups across list refreshes.
$groupToggle = [Windows.RoutedEventHandler]{
    param($s, $e)
    $x = $e.OriginalSource
    if ($x -is [Windows.Controls.Expander] -and $x.Tag) {
        $g = [string]$x.Tag
        # expanders are recreated on every refresh and report the state we gave them: only save real changes
        if ((Test-GroupExpanded $g) -ne $x.IsExpanded) { $script:GroupExpanded[$g] = $x.IsExpanded; Save-UiState }
    }
}
$ui.ProjectList.AddHandler([Windows.Controls.Expander]::ExpandedEvent, $groupToggle)
$ui.ProjectList.AddHandler([Windows.Controls.Expander]::CollapsedEvent, $groupToggle)

$win.add_StateChanged({
    if ($win.WindowState -eq 'Minimized' -and $script:Tray -and $settings.minimizeToTray) { $win.Hide() }
})
$win.add_Closing({
    param($s, $e)
    if (-not $script:Exiting -and $script:Tray -and $settings.closeToTray) { $e.Cancel = $true; $win.Hide() }
})
$win.add_Closed({
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    [Windows.Application]::Current.Shutdown()
})

# ---------------------------------------------------------------- timers / start

$app = [Windows.Application]::Current
if (-not $app) { $app = New-Object Windows.Application }
$app.ShutdownMode = 'OnExplicitShutdown'
$app.add_DispatcherUnhandledException({
    param($s, $e)
    Log "Unexpected error: $($e.Exception.Message)"
    $e.Handled = $true
})

$tickTimer = New-Object Windows.Threading.DispatcherTimer
$tickTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$tickTimer.add_Tick({ On-Tick })

$statusTimer = New-Object Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, $settings.statusRefreshSeconds))
$statusTimer.add_Tick({ Start-StatusPoll })

$script:DataSeconds = 0
$dataTimer = New-Object Windows.Threading.DispatcherTimer
$dataTimer.Interval = [TimeSpan]::FromSeconds(1)
$dataTimer.add_Tick({
    $script:DataSeconds++
    if ($win.IsVisible -and $script:DataSeconds % [Math]::Max(3, $settings.containerRefreshSeconds) -eq 0) { Update-Runtime }
    if ($script:DataSeconds % [Math]::Max(5, $settings.projectRefreshSeconds) -eq 0) { Update-Projects }
})

$script:Projects = @(Get-DcProjectCache)
$script:ProjectsCached = $true
Import-UiState
$ui.ShowHiddenBox.IsChecked = $script:ShowHidden
Import-Config
Log "Dev Control started (distro: $($settings.distro), config: $($settings.wslConfigPath), modes: $($settings.modesDir))."
if (-not $settings.projectsRoot) { Log $DcNoProjectsRoot }
if (-not (Test-Path $settings.modesDir)) { Log "No modes folder at $($settings.modesDir) - set modesDir in settings.json to use WSL modes." }
Start-StatusPoll
$tickTimer.Start(); $statusTimer.Start(); $dataTimer.Start()

if ($SelfTest) { . (Join-Path $AppDir 'SelfTest.ps1') }

if (-not ($Minimized -and $script:Tray)) { $win.Show() }
[void]$app.Run()

$script:Pool.Close()
if ($SelfTest) { exit $script:TestExitCode }
