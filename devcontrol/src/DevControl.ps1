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
using System.ComponentModel;
namespace DevControl {
  public class ChildRow {
    public string Icon {get;set;} public string Name {get;set;} public string Detail {get;set;}
    public string Cpu {get;set;} public string Mem {get;set;} public string Tag {get;set;}
    public string StatusColor {get;set;} public bool HasAction {get;set;} public bool CanAct {get;set;}
  }
  public class WorktreeRow {
    public string Name {get;set;} public string Info {get;set;} public string StatusColor {get;set;}
    public bool CanCode {get;set;} public bool Running {get;set;}
  }
  // Name = folder (the key everywhere); Title = what the card shows (projects.json displayName, else Name).
  // IsExpanded / IsEditing / IsNew / IsActive notify, so opening a card, renaming it or moving the
  // keyboard highlight does not rebuild the list.
  public class ProjectRow : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void Raise(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
    bool _expanded, _editing, _new, _active;
    public bool IsExpanded { get { return _expanded; } set { if (_expanded != value) { _expanded = value; Raise("IsExpanded"); } } }
    public bool IsEditing { get { return _editing; } set { if (_editing != value) { _editing = value; Raise("IsEditing"); } } }
    public bool IsNew { get { return _new; } set { if (_new != value) { _new = value; Raise("IsNew"); } } }
    public bool IsActive { get { return _active; } set { if (_active != value) { _active = value; Raise("IsActive"); } } }
    public string Name {get;set;} public string Title {get;set;} public string Folder {get;set;}
    public string Status {get;set;} public string ShortStatus {get;set;} public string StatusText {get;set;} public string StatusColor {get;set;}
    public string StatusLine {get;set;} public long Recent {get;set;}
    public bool IsRunning {get;set;}
    public string Mode {get;set;} public bool HasMode {get;set;} public bool IsProject {get;set;} public bool IsPinned {get;set;}
    public bool CanRun {get;set;} public bool CanAct {get;set;} public bool CanCode {get;set;} public string CodeTip {get;set;} public bool CodeIsWindows {get;set;}
    public string PrimaryUid {get;set;} public string PrimaryText {get;set;} public string PrimaryTip {get;set;}
    public bool ShowPrimary {get;set;} public bool PrimaryEnabled {get;set;}
    public List<ChildRow> Children {get;set;} public bool HasChildren {get;set;}
    public List<WorktreeRow> Worktrees {get;set;} public bool HasWorktrees {get;set;} public string WorktreeBadge {get;set;}
    public string Group {get;set;} public string GroupLabel {get;set;} public bool HasGroup {get;set;} public bool ShowRun {get;set;}
    public string Facts {get;set;} public string Description {get;set;} public bool HasDescription {get;set;}
    public string Info {get;set;} public bool HasInfo {get;set;} public string Warning {get;set;} public bool HasWarning {get;set;}
    public string Url {get;set;} public bool HasUrl {get;set;} public bool IsHiddenRow {get;set;}
  }
  // One line of the "Projects in group" checklist.
  public class PickItem {
    public string Name {get;set;} public string Title {get;set;} public string Sub {get;set;}
    public bool IsChecked {get;set;} public bool WasChecked {get;set;}
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
$ui.ModeText.ToolTip = "Mode in $($settings.wslConfigPath) (applies at next WSL start)"
$win.add_SourceInitialized({ try { [DevControl.Native]::DarkTitleBar((New-Object Windows.Interop.WindowInteropHelper $win).Handle) } catch { } })

$IconContainer = [string][char]0xE7B8   # Segoe MDL2 "package"
$IconTool      = [string][char]0xE90F   # Segoe MDL2 "repair"
$script:Sep    = "  $([char]0x00B7)  "     # middle dot between the parts of a card's status line (kept out of the ASCII-only source)

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
$script:View = 'all'                # tab: all | running | ungrouped | hidden | g:<group> (saved in ui-state.json)
$script:Sort = 'recent'             # recent | name (saved in ui-state.json)
$script:Used = @{}                  # project name -> unix time last run / opened from Dev Control (ui-state.json)
$script:LogOpen = $false            # activity log expanded (ui-state.json)
$script:Search = ''
$script:ActiveName = $null          # keyboard-highlighted row (search box Up / Down / Enter)
$script:ConfigError = ''            # projects.json could not be read
$script:TabsKey = ''                # what the tab strip was last built from (rebuilt only when it changes)
$script:TrayKey = ''
$script:Seen = $null                # folder names already shown once; $null until the first live listing (ui-state.json)
$script:CardExpanded = @{}          # project name -> details open (this session only)
$script:EditingName = $null         # project whose title is being renamed in place (list rebuilds wait)
$script:AllRows = @()               # every top-level row, hidden ones included, in display order (source of truth for moves)
$script:LastRows = @()              # rows as last rendered (after filters)
$script:Dragging = $false
$script:SyncingFilters = $false     # set while the UI updates filter controls itself (ignore their events)
$script:Ungrouped = 'Ungrouped'     # pseudo group of projects with no "group"
$script:OtherGroup = 'Other containers'
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
$script:DialogWin = $null           # Projects-in-group window while it is open (owner of its message boxes)
$script:EditDlg = $null             # Edit details dialog state while it is open
$script:TestLog = New-Object System.Collections.ArrayList

$script:Pool = [runspacefactory]::CreateRunspacePool(1, 6)
$script:Pool.Open()

function Log([string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    if ($ui.LogBox.Text.Length -gt 60000) { $ui.LogBox.Text = $ui.LogBox.Text.Substring(30000) }
    $ui.LogBox.AppendText($line + "`r`n")
    $ui.LogBox.ScrollToEnd()
    $ui.LastLogText.Text = $line
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
    if ($script:DialogWin) { [Windows.MessageBox]::Show($script:DialogWin, $Message, "Dev Control - $Title", $Buttons, 'Warning', $default) }
    elseif ($win.IsVisible) { [Windows.MessageBox]::Show($win, $Message, "Dev Control - $Title", $Buttons, 'Warning', $default) }
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
        $ui.WslDot.Fill = Get-Brush '#22C55E'; $ui.WslText.Text = 'WSL running'
        $ui.MemText.Text = Format-DcBytes $st.MemoryBytes
    } else {
        $ui.WslDot.Fill = Get-Brush '#6B7280'; $ui.WslText.Text = 'WSL stopped'
        $ui.MemText.Text = ''
    }
    if ($script:Busy) { $ui.WslDot.Fill = Get-Brush '#F59E0B' }
    $detail = @($st.ModeMemory, $(if ($st.ModeProcessors) { "$($st.ModeProcessors) CPU" })) | Where-Object { $_ }
    # the pill shows the mode name; what it asks for is in the tooltip, what the VM really has in LiveText
    $ui.ModeText.Text = [string]$st.Mode
    $ui.ModeText.ToolTip = "Mode '$($st.Mode)' in $($settings.wslConfigPath)" + $(if ($detail) { ": $($detail -join ' / ')" } else { '' }) + ' (applies at the next WSL start)'

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
        $ui.LiveText.Text = ''
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
        $ui.LiveText.Text = "The VM has $($r[0].Cpus) CPU / $(Format-DcBytes $r[0].MemBytes)"
    }
}

# ---------------------------------------------------------------- project config (projects.json)

function Get-Cfg([string]$Name) { $script:ProjectCfg[$Name] }
function Get-CfgValue($Cfg, [string]$Key, $Default) {
    if ($Cfg -and $Cfg.PSObject.Properties[$Key] -and $null -ne $Cfg.$Key) { $Cfg.$Key } else { $Default }
}
function Test-Pinned([string]$Name) { [bool](Get-CfgValue (Get-Cfg $Name) 'pinned' $false) }

# Per-user view state (tab, sort, log open, when projects were last used, folders already seen) -
# survives restarts, separate from projects.json. Keys of older versions (expanded, showHidden,
# statusFilter, groupFilter) are ignored and dropped on the next save.
function Import-UiState {
    try {
        if (Test-Path $script:UiStatePath) {
            $j = Get-Content -Raw -Path $script:UiStatePath | ConvertFrom-Json
            if ($j.PSObject.Properties['view'] -and $j.view) { $script:View = [string]$j.view }
            if ($j.PSObject.Properties['sort'] -and @('recent', 'name') -contains $j.sort) { $script:Sort = [string]$j.sort }
            $script:LogOpen = [bool]$j.logOpen
            if ($j.used) { foreach ($p in $j.used.PSObject.Properties) { $script:Used[$p.Name] = [int64]$p.Value } }
            if ($j.PSObject.Properties['seen'] -and $null -ne $j.seen) {
                $script:Seen = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($n in @($j.seen)) { [void]$script:Seen.Add([string]$n) }
            }
        }
    } catch { Log "ui-state.json ignored: $($_.Exception.Message)" }
}

function Save-UiState {
    try {
        $used = [ordered]@{}
        foreach ($k in @($script:Used.Keys | Sort-Object)) { $used[$k] = $script:Used[$k] }
        $state = [ordered]@{ view = $script:View; sort = $script:Sort; logOpen = $script:LogOpen; used = $used }
        if ($script:Seen) { $state.seen = @($script:Seen | Sort-Object) }
        [IO.File]::WriteAllText($script:UiStatePath, (ConvertTo-DcJson $state), (New-Object Text.UTF8Encoding $false))
    } catch { Log "Could not save ui-state.json: $($_.Exception.Message)" }
}

# Recency = the later of "last used from Dev Control" and the folder's own last activity (git commit or
# newest file, from Get-DcProjects).
function Set-Used([string]$Name) {
    if (-not $Name) { return }
    $script:Used[$Name] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Save-UiState
}

# "New" badge: a folder that appeared since the user last looked. The first live listing (fresh install,
# or an upgrade from a version without this) marks everything as seen, so only later folders get the badge.
function Update-Seen {
    $names = @($script:Projects | ForEach-Object { [string]$_.Name })
    if ($null -eq $script:Seen) {
        $script:Seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($n in $names) { [void]$script:Seen.Add($n) }
        Save-UiState
        return
    }
    # forget folders that no longer exist, so the lists do not grow forever
    $gone = @($script:Seen | Where-Object { $names -notcontains $_ })
    $goneUsed = @($script:Used.Keys | Where-Object { $names -notcontains $_ })
    foreach ($n in $gone) { [void]$script:Seen.Remove($n) }
    foreach ($n in $goneUsed) { $script:Used.Remove($n) }
    if ($gone.Count + $goneUsed.Count) { Save-UiState }
}

function Test-NewProject([string]$Name) { $script:Seen -and -not $script:ProjectsCached -and -not $script:Seen.Contains($Name) }

function Set-Seen([string]$Name) {
    if (-not $script:Seen -or $script:Seen.Contains($Name)) { return }
    [void]$script:Seen.Add($Name)
    Save-UiState
    $row = Get-RowByName $Name
    if ($row) { $row.IsNew = $false }
}

function Import-Config([switch]$Quiet) {
    try {
        $script:ProjectCfg = Get-DcProjectConfig
        $script:ConfigMeta = Get-DcConfigFile
        $script:ConfigError = ''
        if (-not $Quiet) { Log "Loaded projects.json ($($script:ProjectCfg.Count) configured project(s))." }
    } catch {
        $script:ProjectCfg = @{}
        $script:ConfigError = 'projects.json has an error - see the log (menu ... > Edit projects.json).'
        Log "projects.json could not be read: $($_.Exception.Message)"
    }
    Update-Enablement
}

# ---------------------------------------------------------------- rendering

function Get-Idle { -not $script:Busy -and -not $script:PendingLifecycle }

function Update-Enablement {
    $run  = $script:State.Running -eq $true
    $idle = Get-Idle
    $free = $idle -and -not $script:Seq
    # Only the WSL buttons that do something now: Start while stopped; Stop while running, plus
    # "Switch to <mode>" when another mode is picked in the combo.
    $pick = [string]$ui.ModeCombo.SelectedItem
    $switch = $run -and $pick -and $pick -ne $script:State.Mode
    $ui.StartBtn.IsEnabled = $free
    $ui.StartBtn.Content = if ($switch) { "Switch to $pick" } else { 'Start WSL' }
    $ui.StartBtn.Visibility = if (-not $run -or $switch) { 'Visible' } else { 'Collapsed' }
    $ui.StopWslBtn.IsEnabled = $free -and $run
    $ui.StopWslBtn.Visibility = if ($run) { 'Visible' } else { 'Collapsed' }
    $ui.CodeOpenBtn.IsEnabled = $free
    $ui.CodeOpenWinBtn.IsEnabled = $true
    $ui.CodeQuitBtn.IsEnabled = $free -and $run -and $script:VSCodeCount -gt 0
    $ui.CodeQuitBtn.Visibility = if ($run -and $script:VSCodeCount -gt 0) { 'Visible' } else { 'Collapsed' }
    $ui.CodeText.Text = if ($run -and $script:VSCodeCount -gt 0) { "Quit ($($script:VSCodeCount))" } else { '' }
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
    $s = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $Epoch
    if ($s -lt 3600) { return 'just now' }
    if ($s -lt 86400) { return "$([int][Math]::Floor($s / 3600))h ago" }
    $d = [int][Math]::Floor($s / 86400)
    if ($d -eq 1) { 'yesterday' } elseif ($d -lt 14) { "$d days ago" } elseif ($d -lt 60) { "$([int][Math]::Floor($d / 7)) weeks ago" }
    elseif ($d -lt 730) { "$([int][Math]::Floor($d / 30)) months ago" } else { "$([int][Math]::Floor($d / 365)) years ago" }
}

# A project with no "group" in projects.json is Ungrouped (its own tab, where new folders show up).
function Get-GroupName($p) {
    $g = [string](Get-CfgValue (Get-Cfg $p.Name) 'group' '')
    if ($g.Trim()) { return $g.Trim() }
    $script:Ungrouped
}

# The user's groups in tab order: projects.json "groups" first (empty ones too), then any group a
# project names that the list lacks. Ungrouped is not a real group and is not included.
function Get-AllGroups {
    $cfg = @(Get-CfgValue $script:ConfigMeta 'groups' @() | Where-Object { $_ -and $_ -ne $script:Ungrouped })
    $used = @($script:Projects | ForEach-Object { Get-GroupName $_ } | Where-Object { $_ -ne $script:Ungrouped })
    @(@($cfg) + @($used) | Select-Object -Unique)
}

function Get-DisplayName([string]$Name) {
    $d = ([string](Get-CfgValue (Get-Cfg $Name) 'displayName' '')).Trim()
    if ($d) { $d } else { $Name }
}

function Get-WorktreeInfo($p) {
    $state = if ($p.Ahead -eq 0) { 'fully merged' } else { "$($p.Ahead) commit(s) not merged" }
    $clean = if ($p.Dirty -eq 0) { 'clean' } else { "$($p.Dirty) uncommitted file(s)" }
    "branch $($p.Branch)  -  $state, $clean" + $(if ($p.Ahead -eq 0 -and $p.Dirty -eq 0) { '  -  safe to remove' } else { '' })
}

# Every top-level row, hidden ones included, sorted for display. Git worktrees without a group of
# their own are not top-level rows: they are listed in their main project's details.
function Get-ProjectRows {
    $run  = $script:State.Running -eq $true
    $idle = Get-Idle
    $root = ([string]$settings.projectsRoot).TrimEnd('/')
    $flavor = if ($settings.codeFlavor -eq 'windows') { 'Windows VS Code (Remote - WSL)' } else { 'Linux VS Code' }
    $usedC = @{}; $usedT = @{}
    $rows = New-Object System.Collections.ArrayList
    $byName = @{}
    foreach ($p in $script:Projects) {
        $cfg  = Get-Cfg $p.Name
        $dir  = if ($p.PSObject.Properties['Dir'] -and $p.Dir) { [string]$p.Dir } else { "$root/$($p.Name)" }
        $cdir0 = $dir   # container match below uses the Linux path; the card shows the configured one
        $cpath = ([string](Get-CfgValue $cfg 'path' '')).Trim()
        if ($cpath) { $dir = $cpath }
        $pflavor = [string](Get-CfgValue $cfg 'codeFlavor' '')
        if ($pflavor -notin @('linux', 'windows')) { $pflavor = if (Test-DcWindowsPath $cpath) { 'windows' } else { '' } }
        $cdir = if ($p.PSObject.Properties['ComposeDir'] -and $p.ComposeDir) { $p.ComposeDir } else { $cdir0 }
        $slug = Get-DcSlug $p.Name
        $policy = Get-ComposePolicy $p
        $tools = @(Get-CfgValue $cfg 'tools' @() | Where-Object { $_ })
        $r = New-Object DevControl.ProjectRow
        $r.Name = $p.Name; $r.Title = Get-DisplayName $p.Name; $r.Folder = $dir; $r.IsProject = $true
        $r.Group = Get-GroupName $p; $r.HasGroup = $r.Group -ne $script:Ungrouped
        $r.GroupLabel = if ($r.HasGroup) { $r.Group } else { 'No group' }
        $r.Mode = [string](Get-CfgValue $cfg 'mode' ''); $r.HasMode = [bool]$r.Mode
        $r.Url = [string](Get-CfgValue $cfg 'url' ''); $r.HasUrl = [bool]$r.Url
        $r.Description = [string](Get-CfgValue $cfg 'description' ''); $r.HasDescription = [bool]$r.Description.Trim()
        $r.IsPinned = Test-Pinned $p.Name
        $r.ShowRun = $policy.Allowed -or $tools.Count -gt 0
        $r.CodeTip = if ($pflavor -eq 'windows' -and (Test-DcWindowsPath $cpath)) { 'Open in Windows VS Code (the project is on the Windows drive)' }
                     elseif ($pflavor -eq 'windows') { 'Open in Windows VS Code (Remote - WSL; the project''s codeFlavor); starts WSL first if it is stopped' }
                     elseif ($pflavor -eq 'linux') { 'Open in Linux VS Code (the project''s codeFlavor); starts WSL first if it is stopped' }
                     else { "Open in $flavor (the editor setting codeFlavor picks); starts WSL first if it is stopped" }
        $r.CodeIsWindows = if ($pflavor) { $pflavor -eq 'windows' } else { $settings.codeFlavor -eq 'windows' }
        $last = if ($p.PSObject.Properties['LastActive'] -and $p.LastActive) { [int64]$p.LastActive } else { [int64]0 }
        $r.Recent = [Math]::Max($last, [int64]$(if ($script:Used.ContainsKey($p.Name)) { $script:Used[$p.Name] } else { 0 }))
        $r.Children = New-Object 'System.Collections.Generic.List[DevControl.ChildRow]'
        $r.Worktrees = New-Object 'System.Collections.Generic.List[DevControl.WorktreeRow]'
        $cs = @($script:Containers | Where-Object { $_.Dir -eq $cdir })
        $ts = @($script:Tools | Where-Object { $_.Slug -eq $slug })
        foreach ($c in $cs) { $usedC[$c.Id] = 1; $r.Children.Add((New-ContainerChild $c)) }
        foreach ($t in $ts) { $usedT["$($t.Slug)/$($t.Tool)"] = 1; $r.Children.Add((New-ToolChild $t $p.Name)) }

        # what Dev Control detected, in one line
        $facts = @("Folder: $dir")
        if ($p.Compose) {
            $cf = ([string]$p.ComposeFile)
            if ($cf.StartsWith("$dir/")) { $cf = $cf.Substring($dir.Length + 1) }
            $facts += "compose: $cf" + $(if ($p.ComposeName) { " (project '$($p.ComposeName)')" } else { '' })
        } else { $facts += 'no compose file' }
        if ($tools.Count) { $facts += "$($tools.Count) tool(s)" }
        if ($p.PSObject.Properties['LastActive'] -and $p.LastActive) { $facts += "last change $(Format-Age $p.LastActive)" }
        $r.Facts = $facts -join '   |   '

        $info = @()
        if ($p.PSObject.Properties['Worktree'] -and $p.Worktree) { $info += "Git worktree of $($p.Parent): $(Get-WorktreeInfo $p)" }
        elseif (-not $r.ShowRun -and -not $p.Compose) { $info += 'Nothing to run here: no compose file and no tools. VS Code opens it; Edit details adds tools.' }
        $r.IsHiddenRow = [bool](Get-CfgValue $cfg 'hidden' $false)
        if ($r.IsHiddenRow) { $info = @('hidden (menu ... > Unhide)') + $info }
        $r.Info = $info -join '   '; $r.HasInfo = [bool]$r.Info
        $r.Warning = (@([string](Get-CfgValue $cfg 'warning' ''), $policy.Reason) | Where-Object { $_ }) -join '  '
        $r.HasWarning = [bool]$r.Warning

        $nt = @($ts | Where-Object { $_.Running }).Count
        $r.IsRunning = $run -and ($cs.Count + $nt -gt 0)
        $op = $script:ProjectOps[$p.Name]
        if ($op) { $r.Status = "$op..."; $r.ShortStatus = $r.Status; $r.StatusText = $r.Status; $r.StatusColor = '#3B82F6' }
        elseif (-not $run) { $r.Status = 'WSL stopped'; $r.ShortStatus = 'WSL stopped'; $r.StatusText = 'Stopped'; $r.StatusColor = '#6B7280' }
        elseif ($r.IsRunning) {
            $parts = @(); if ($cs.Count) { $parts += "$($cs.Count) container(s)" }; if ($nt) { $parts += "$nt tool(s)" }
            $r.ShortStatus = $parts -join ', '; $r.Status = "running  -  $($r.ShortStatus)"; $r.StatusText = 'Running'; $r.StatusColor = '#22C55E'
        }
        elseif ($p.Compose -and $p.Status -and $p.Status -ne 'down') {
            $r.Status = "compose: $($p.Status)"; $r.ShortStatus = $p.Status; $r.StatusText = $p.Status; $r.StatusColor = '#F59E0B'
        }
        else {
            $r.ShortStatus = 'stopped'; $r.StatusText = 'Stopped'
            $r.Status = if ($r.ShowRun) { 'stopped' } else { 'editor only' }
            $r.StatusColor = '#6B7280'
        }
        $free = $idle -and -not $script:Seq -and -not $op
        $r.CanRun = $free
        $r.CanAct = $free -and $run
        $r.CanCode = $free
        # one main action on the collapsed card: Stop while something runs, else Run (if there is anything to run)
        if ($r.IsRunning -or $r.StatusColor -eq '#F59E0B') {
            $r.PrimaryUid = 'stop'; $r.PrimaryText = 'Stop'; $r.PrimaryEnabled = $r.CanAct; $r.ShowPrimary = $true
            $r.PrimaryTip = 'Stop background tools, compose down'
        } elseif ($r.ShowRun) {
            $r.PrimaryUid = 'run'; $r.PrimaryText = 'Run'; $r.PrimaryEnabled = $r.CanRun; $r.ShowPrimary = $true
            $r.PrimaryTip = "Start WSL$(if ($r.Mode) { " ($($r.Mode) mode)" }), compose up, start tools$(if (Get-CfgValue $cfg 'openVSCode' $true) { ', open VS Code' })"
        }
        $r.IsNew = Test-NewProject $p.Name
        $r.IsExpanded = [bool]$script:CardExpanded[$p.Name]
        $r.IsEditing = $script:EditingName -eq $p.Name
        $byName[$p.Name] = $r
        [void]$rows.Add(@{ Row = $r; P = $p; Cfg = $cfg })
    }

    # worktrees without a group of their own go into their main project's details
    $top = New-Object System.Collections.ArrayList
    foreach ($x in $rows) {
        $p = $x.P; $r = $x.Row
        $isWt = $p.PSObject.Properties['Worktree'] -and $p.Worktree
        $parent = if ($isWt) { $byName[[string]$p.Parent] } else { $null }
        if ($parent -and -not (Get-CfgValue $x.Cfg 'group' '')) {
            $w = New-Object DevControl.WorktreeRow
            $w.Name = $p.Name; $w.CanCode = $r.CanCode; $w.Running = $r.IsRunning
            $w.Info = (Get-WorktreeInfo $p) + $(if ($r.IsRunning) { "  -  running: $($r.ShortStatus)" } else { '' })
            $w.StatusColor = if ($r.IsRunning) { '#22C55E' } else { '#6B7280' }
            $parent.Worktrees.Add($w)
            $parent.Recent = [Math]::Max($parent.Recent, $r.Recent)   # work in a worktree counts for the repo
            foreach ($c in $r.Children) { $c.Detail = "worktree $($p.Name)  |  $($c.Detail)"; $parent.Children.Add($c) }
            continue
        }
        [void]$top.Add($r)
    }
    foreach ($r in $top) {
        $r.HasChildren = $r.Children.Count -gt 0
        $r.HasWorktrees = $r.Worktrees.Count -gt 0
        if ($r.HasWorktrees) { $r.WorktreeBadge = "$($r.Worktrees.Count) worktree$(if ($r.Worktrees.Count -ne 1) { 's' })" }
        # second line of the card: what is going on, then how recently it was used
        $parts = @()
        if ($script:ProjectOps[$r.Name]) { $parts += $r.Status }
        elseif ($r.IsRunning) { $parts += "Running: $($r.ShortStatus)" }
        elseif ($r.StatusColor -eq '#F59E0B') { $parts += $r.Status }
        $wr = @($r.Worktrees | Where-Object { $_.Running }).Count
        if ($wr) { $parts += "$wr worktree(s) running" }
        $age = Format-Age $r.Recent
        if ($age) { $parts += $age }
        $r.StatusLine = $parts -join $script:Sep
    }

    $otherC = @($script:Containers | Where-Object { -not $usedC[$_.Id] })
    $otherT = @($script:Tools | Where-Object { -not $usedT["$($_.Slug)/$($_.Tool)"] })
    if ($otherC.Count + $otherT.Count -gt 0) {
        $r = New-Object DevControl.ProjectRow
        $r.Name = 'Not part of a listed project'; $r.Title = 'Other containers and tools'; $r.IsProject = $false
        $r.Group = $script:OtherGroup; $r.GroupLabel = ''
        $r.Status = "$($otherC.Count) container(s), $($otherT.Count) tool(s)"; $r.StatusText = "$($otherC.Count + $otherT.Count) running"; $r.StatusColor = '#22C55E'
        $r.StatusLine = "Running: $($r.Status) whose folder is not a listed project"
        $r.IsRunning = $true
        $r.Facts = 'Containers and tools whose folder is not one of the projects above.'
        $r.Children = New-Object 'System.Collections.Generic.List[DevControl.ChildRow]'
        foreach ($c in $otherC) { $r.Children.Add((New-ContainerChild $c)) }
        foreach ($t in $otherT) { $r.Children.Add((New-ToolChild $t '')) }
        $r.HasChildren = $true
        $r.IsExpanded = if ($script:CardExpanded.ContainsKey($r.Name)) { [bool]$script:CardExpanded[$r.Name] } else { $false }
        [void]$top.Add($r)
    }
    , (Sort-Rows $top)
}

# Pinned first, then most recently used (or A-Z), then the "other containers" row.
function Sort-Rows($Rows) {
    $key = if ($script:Sort -eq 'name') { @{ Expression = { $_.Title } } } else { @{ Expression = { $_.Recent }; Descending = $true } }
    $kind = @{ Expression = { if (-not $_.IsProject) { 2 } elseif ($_.IsPinned) { 0 } else { 1 } } }
    $sorted = New-Object System.Collections.ArrayList
    foreach ($r in @($Rows | Sort-Object $kind, $key, @{ Expression = { $_.Title } })) { [void]$sorted.Add($r) }
    , $sorted
}

function Test-Running($r) { $r.IsRunning -or @($r.Worktrees | Where-Object { $_.Running }).Count -gt 0 }

# Tabs: all | running | g:<group> | ungrouped | hidden. Hidden projects only show in the Hidden tab.
function Test-InView($r, [string]$View) {
    if ($View -eq 'hidden') { return [bool]($r.IsProject -and $r.IsHiddenRow) }
    if ($r.IsHiddenRow) { return $false }
    if ($View -eq 'running') { return [bool](Test-Running $r) }
    if ($View -eq 'ungrouped') { return [bool]($r.IsProject -and -not $r.HasGroup) }
    if ($View.StartsWith('g:')) { return [bool]($r.IsProject -and $r.Group -eq $View.Substring(2)) }
    $true
}

# Every word of the query must appear in the title, folder name, path, group, mode, description or a worktree name.
function Test-SearchMatch($r, [string]$Query) {
    if (-not $Query) { return $true }
    $hay = (@($r.Title, $r.Name, $r.Folder, $r.GroupLabel, $r.Mode, $r.Description) + @($r.Worktrees | ForEach-Object { $_.Name }) | Where-Object { $_ }) -join "`n"
    foreach ($w in ($Query -split '\s+' | Where-Object { $_ })) {
        if ($hay.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    $true
}

# The tab strip: key, label, count. Ungrouped and Hidden appear only when they have something.
function Get-Views {
    $vis = @($script:AllRows | Where-Object { $_.IsProject -and -not $_.IsHiddenRow })
    $views = New-Object System.Collections.ArrayList
    [void]$views.Add(@{ Key = 'all'; Label = 'All'; Count = $vis.Count })
    [void]$views.Add(@{ Key = 'running'; Label = 'Running'; Count = @($vis | Where-Object { Test-Running $_ }).Count })
    foreach ($g in Get-AllGroups) { [void]$views.Add(@{ Key = "g:$g"; Label = $g; Count = @($vis | Where-Object { $_.Group -eq $g }).Count }) }
    $n = @($vis | Where-Object { -not $_.HasGroup }).Count
    if ($n -or $script:View -eq 'ungrouped') { [void]$views.Add(@{ Key = 'ungrouped'; Label = $script:Ungrouped; Count = $n }) }
    $n = @($script:AllRows | Where-Object { $_.IsProject -and $_.IsHiddenRow }).Count
    if ($n) { [void]$views.Add(@{ Key = 'hidden'; Label = 'Hidden'; Count = $n }) }
    , $views
}

# Rebuilt only when a tab, a count or the selection changes (so a drag over the tabs is not interrupted).
function Update-Tabs($Views) {
    $key = (@($Views | ForEach-Object { "$($_.Key)=$($_.Count)" }) -join '|') + "#$($script:View)"
    if ($key -eq $script:TabsKey) { return }
    $script:TabsKey = $key
    $script:SyncingFilters = $true
    try {
        $ui.ViewTabs.Children.Clear()
        foreach ($v in $Views) {
            $rb = New-Object Windows.Controls.RadioButton
            $rb.Style = $win.FindResource('Tab'); $rb.GroupName = 'View'; $rb.Tag = $v.Key
            $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
            $t1 = New-Object Windows.Controls.TextBlock; $t1.Text = $v.Label
            $t2 = New-Object Windows.Controls.TextBlock; $t2.Text = [string]$v.Count; $t2.Margin = '7,0,0,0'; $t2.Foreground = Get-Brush '#6B7280'
            [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
            $rb.Content = $sp
            $rb.IsChecked = $v.Key -eq $script:View
            $rb.ToolTip = if ($v.Key.StartsWith('g:')) { "Drop a project here to move it into '$($v.Label)'. Right-click to rename, move or delete the group." }
                          elseif ($v.Key -eq 'ungrouped') { 'Projects in no group (new folders land here). Drop a project here to take it out of its group.' }
                          elseif ($v.Key -eq 'hidden') { 'Hidden projects. Drop a project here to hide it.' }
                          elseif ($v.Key -eq 'running') { 'Projects with running containers or background tools' }
                          else { 'Every project except hidden ones' }
            [void]$ui.ViewTabs.Children.Add($rb)
        }
        $nb = New-Object Windows.Controls.Button
        $nb.Style = $win.FindResource('BtnGhost'); $nb.Tag = 'newgroup'; $nb.AllowDrop = $true; $nb.Margin = '0,0,4,6'; $nb.Padding = '10,4'
        $nb.Foreground = Get-Brush '#9AA0A6'
        $nb.Content = '+ New group'
        $nb.ToolTip = 'Create a group. Drop a project here to put it in a new group.'
        [void]$ui.ViewTabs.Children.Add($nb)
    } finally { $script:SyncingFilters = $false }
}

function Set-View([string]$View) {
    if ($script:SyncingFilters -or $script:View -eq $View) { return }
    $script:View = $View
    Save-UiState
    Show-Projects
}

function Show-Projects {
    if ($script:Dragging -or $script:EditingName) { return }   # a rebuild would pull the item out from under the mouse / the caret
    $all = Get-ProjectRows
    $script:AllRows = @($all)
    $views = Get-Views
    if (-not @($views | Where-Object { $_.Key -eq $script:View }).Count) { $script:View = 'all' }   # group renamed / deleted
    $q = $script:Search.Trim()
    $rows = New-Object System.Collections.ArrayList
    $rest = New-Object System.Collections.ArrayList
    foreach ($r in $all) {
        if (-not (Test-InView $r $script:View) -or -not (Test-SearchMatch $r $q)) { continue }
        # while searching, titles that start with the query come first
        if ($q -and $r.Title.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)) { [void]$rows.Add($r) } else { [void]$rest.Add($r) }
    }
    foreach ($r in $rest) { [void]$rows.Add($r) }
    if ($script:ActiveName -and -not @($rows | Where-Object { $_.Name -eq $script:ActiveName }).Count) { $script:ActiveName = $null }
    if ($q -and -not $script:ActiveName -and $rows.Count) { $script:ActiveName = $rows[0].Name }
    foreach ($r in $rows) { $r.IsActive = $r.Name -eq $script:ActiveName }
    $script:LastRows = @($rows)
    $ui.ProjectList.ItemsSource = $rows
    Update-Tabs $views

    $inGroup = $script:View.StartsWith('g:')
    $ui.GroupTools.Visibility = if ($inGroup) { 'Visible' } else { 'Collapsed' }
    $ui.SortText.Text = if ($script:Sort -eq 'name') { 'Name' } else { 'Recent' }
    $label = @($views | Where-Object { $_.Key -eq $script:View })[0].Label
    $ui.EmptyAddBtn.Visibility = 'Collapsed'
    $ui.EmptyText.Text = if (-not $settings.projectsRoot) { $DcNoProjectsRoot }
        elseif ($q) { "No project matches '$q'" + $(if ($script:View -ne 'all') { " in $label." } else { '.' }) }
        elseif ($inGroup) { $ui.EmptyAddBtn.Visibility = 'Visible'; "No projects in $label yet. Drop a project on its tab, or:" }
        elseif ($script:View -eq 'running') { 'Nothing is running.' }
        else { 'No projects yet.' }
    $ui.EmptyState.Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $ui.ProjectsHint.Text = if ($script:ConfigError) { $script:ConfigError }
        elseif ($settings.projectsRoot -and $script:State.Running -eq $false) { 'WSL is stopped. Run starts it in the project''s mode; the list is from the last time it ran.' }
        else { '' }
    $ui.ProjectsHint.Visibility = if ($ui.ProjectsHint.Text) { 'Visible' } else { 'Collapsed' }
    Update-TrayRunMenu
}

# ---------------------------------------------------------------- data refresh (Linux queries)

function Update-Projects {
    if (-not $settings.projectsRoot) { return }   # nothing to list; Show-Projects says why
    if (-not $script:State.Running -or $script:Busy -or $script:PendingLifecycle -or (Test-Job 'projects')) { return }
    Start-Bg -Name 'projects' -Kind 'data' -Work { $p = Get-DcProjects; Save-DcProjectCache $p; $p } -Done {
        param($r, $e)
        if ($e) { if ($script:State.Running) { Log "Project list failed: $($e.Message)" }; return }
        $script:Projects = @($r | Where-Object { $_ }); $script:ProjectsCached = $false
        Update-Seen
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
        if ($e -and $e.Message -like 'WSL did not stop*') { Invoke-ForceStopFlow $c.Then ($c.Type -eq 'start'); return }
        if ($c.Then) { & $c.Then (-not $e) }
    }
}

# Offered when wsl --shutdown (and --shutdown --force) left WSL running. Needs admin (UAC).
function Invoke-ForceStopFlow([scriptblock]$Then, [bool]$WasRestart) {
    $msg = "WSL did not stop.`n`nForce-stop it? This ends the WSL virtual machine directly " +
           "(Windows asks for administrator permission). Unsaved work in Linux is lost.`n`n" +
           "Task Manager cannot end vmmemWSL; this is the way to stop it without restarting Windows."
    if (-not (Confirm-Dc $msg 'Force stop WSL')) { Log 'Force stop cancelled.'; if ($Then) { & $Then $false }; return }
    Log 'Force-stopping WSL...'
    $script:Busy = $true
    Update-Enablement
    Start-Bg -Name 'lifecycle' -Kind 'action' -Work { Stop-DcWslForce } -Context @{ Then = $Then; WasRestart = $WasRestart } -Done {
        param($r, $e, $c)
        $script:Busy = $false
        if ($e) { Log "FAILED: $($e.Message)" } else { Log ($r -join ' ') }
        $script:State.Running = $null
        Start-StatusPoll
        Update-Enablement
        # A mode switch stopped here: WSL is down but not started in the new mode.
        if ($c.WasRestart -and -not $e) { Log 'Start WSL again to switch modes.' }
        if ($c.Then) { & $c.Then ((-not $e) -and -not $c.WasRestart) }
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
        { $_ -in @('code', 'codewin', 'codedef') } {
            # Both editors open the Linux folder (Windows VS Code through Remote - WSL), so WSL comes first.
            # codedef = the card's VS Code button: the codeFlavor setting picks the editor.
            $fl = switch ($Kind) { 'codewin' { 'windows' } 'code' { 'linux' } default { Get-DcCodeFlavor } }
            if (-not $script:State.Running) { $steps += @{ Type = 'wsl'; Mode = $mode; Text = 'starting WSL' } }
            $steps += @{ Type = 'code'; Flavor = $fl; Text = "opening $(if ($fl -eq 'windows') { 'Windows' } else { 'Linux' }) VS Code" }
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
    if ($Kind -notin @('run', 'code', 'codewin', 'codedef') -and -not $script:State.Running) { Log "WSL is stopped - nothing to $Kind."; return }
    $steps = Get-SequenceSteps $Kind $Name
    if ($Kind -in @('run', 'code', 'codewin', 'codedef')) { Set-Used $Name }   # recency sort
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
        'code'      { Open-Code $q.Name $script:StepDone $st.Flavor }
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

# An empty $Name opens a window with no folder loaded. $Flavor: 'linux' / 'windows' / '' (= codeFlavor setting).
function Open-Code([string]$Name, [scriptblock]$Then, [string]$Flavor) {
    $which = switch ($Flavor) { 'windows' { 'Windows VS Code' } 'linux' { 'Linux VS Code' } default { 'VS Code' } }
    Log $(if ($Name) { "Opening $Name in $which..." } else { "Opening an empty $which window..." })
    Start-Bg -Name "code:$Name" -Kind 'action' -Work { param($n, $f) Open-DcVSCode $n $f } -ArgList @($Name, $Flavor) -Context @{ Then = $Then } -Done {
        param($r, $e, $c)
        if ($e) { Log "VS Code failed: $($e.Message)" } else { Log ($r -join ' ') }
        Update-Runtime
        if ($c.Then) { & $c.Then (-not $e) }
    }
}

# VS Code with no folder. Linux VS Code runs in WSL, so WSL has to be up first; Windows VS Code opens
# a plain local window and needs neither WSL nor an idle app.
function Open-EmptyCode([string]$Flavor = 'linux') {
    if ($Flavor -eq 'windows') { Open-Code '' $null 'windows'; return }
    if ($script:Seq -or $script:Busy -or $script:PendingLifecycle) { Log 'Busy - wait for the current operation to finish.'; return }
    if ($script:State.Running) { Open-Code '' $null 'linux'; return }
    Start-WslFlow '' { param($ok) if ($ok) { Open-Code '' $null 'linux' } }
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

# ---------------------------------------------------------------- arranging projects (names, groups, order, pin, hide)
# Every change re-reads projects.json from disk, edits it, and writes it back (so edits made in
# Notepad meanwhile are kept), then reloads. Names, order and groups therefore persist across restarts.

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
# text setting: empty removes the key, so the file only holds what the user actually set
function Set-CfgText($Obj, [string]$Key, [string]$Value) { if ($Value.Trim()) { Set-CfgProp $Obj $Key $Value.Trim() } else { Remove-CfgProp $Obj $Key } }

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

function Get-GroupMembers([string]$Group) { @($script:AllRows | Where-Object { $_.IsProject -and $_.Group -eq $Group } | ForEach-Object { $_.Name }) }
function Get-RowByName([string]$Name) { $script:AllRows | Where-Object { $_.IsProject -and $_.Name -eq $Name } | Select-Object -First 1 }

# A typed group name matched against the existing ones, ignoring case ('active' -> 'Active').
function Resolve-GroupName([string]$Group) {
    $g = $Group.Trim()
    $hit = @(@($script:Ungrouped) + @(Get-AllGroups) | Where-Object { $_ -ieq $g })
    if ($hit.Count) { $hit[0] } else { $g }
}
function Test-ReservedGroup([string]$Group) { @($script:OtherGroup, 'All groups') -contains $Group }

# Puts $Name into $Group ('' or Ungrouped = no group). A group that does not exist yet is created
# (appended to the tab order). The list is sorted by recency or name, so no "order" is kept.
function Move-ProjectTo([string]$Name, [string]$Group) {
    $Group = Resolve-GroupName $Group
    if (Test-ReservedGroup $Group) { Log "'$Group' is reserved - pick another group name."; return }
    $ung = -not $Group -or $Group -eq $script:Ungrouped
    $row = Get-RowByName $Name
    if ($row -and (($ung -and -not $row.HasGroup) -or $row.Group -eq $Group)) { return }   # already there
    $allGroups = Get-AllGroups
    Edit-Config "Moved $(Get-DisplayName $Name) to $(if ($ung) { 'no group' } else { "group '$Group'" })." {
        param($c)
        $e = Get-CfgEntry $c $Name
        Remove-CfgProp $e 'order'
        if ($ung) { Remove-CfgProp $e 'group'; return }
        Set-CfgProp $e 'group' $Group
        if ($allGroups -notcontains $Group) { Set-CfgProp $c 'groups' @(@($allGroups) + $Group) }
    }
    Set-Seen $Name
}

# Makes $Names exactly the members of $Group: listed projects move in (from wherever they were),
# current members that are not listed become Ungrouped. Hidden members are left alone unless listed.
function Set-GroupMembers([string]$Group, [string[]]$Names) {
    $Names = @($Names | Where-Object { $_ })
    $cur = @($script:Projects | Where-Object { (Get-GroupName $_) -eq $Group } | ForEach-Object { $_.Name })
    $add = @($Names | Where-Object { $cur -notcontains $_ })
    $drop = @($cur | Where-Object { $Names -notcontains $_ -and -not (Get-RowByName $_).IsHiddenRow })
    if (-not ($add.Count + $drop.Count)) { return }
    $allGroups = Get-AllGroups
    Edit-Config "Group '$Group': $($add.Count) added, $($drop.Count) removed." {
        param($c)
        foreach ($n in $add) { $e = Get-CfgEntry $c $n; Set-CfgProp $e 'group' $Group; Remove-CfgProp $e 'order' }
        foreach ($n in $drop) { $e = Get-CfgEntry $c $n; Remove-CfgProp $e 'group'; Remove-CfgProp $e 'order' }
        if ($allGroups -notcontains $Group) { Set-CfgProp $c 'groups' @(@($allGroups) + $Group) }
    }
    foreach ($n in $add) { Set-Seen $n }
}

# An empty group is kept in projects.json "groups", so it shows as a tab and can be filled.
# Returns the group name when it was created.
function Add-Group([string]$Group) {
    $Group = Resolve-GroupName $Group
    if (-not $Group) { return }
    if ($Group -eq $script:Ungrouped -or (Test-ReservedGroup $Group)) { Log "'$Group' is reserved - pick another group name."; return }
    $allGroups = Get-AllGroups
    if ($allGroups -contains $Group) { Log "Group '$Group' already exists."; return }
    Edit-Config "Created group '$Group'." { param($c) Set-CfgProp $c 'groups' @(@($allGroups) + $Group) }
    $Group
}

# "+ New group": name it, open its tab, then pick its projects (or, when a project was dropped on
# the button, put that one in).
function New-GroupFlow([string]$Project = '') {
    $prompt = if ($Project) { "New group for '$(Get-DisplayName $Project)':" } else { 'Name of the new group:' }
    $g = Read-DcText 'New group' $prompt
    if (-not $g) { return }
    if ($Project) { Move-ProjectTo $Project $g; return }
    $g = Add-Group $g
    if (-not $g) { return }
    $script:View = "g:$g"; Save-UiState; Show-Projects
    Show-GroupMembers $g
}

function Move-GroupStep([string]$Group, [int]$Delta) {
    $order = New-Object System.Collections.ArrayList
    foreach ($g in (Get-AllGroups)) { [void]$order.Add($g) }
    $i = $order.IndexOf($Group); $j = $i + $Delta
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $order.Count) { return }
    $order.RemoveAt($i); $order.Insert($j, $Group)
    Edit-Config "Moved group '$Group' $(if ($Delta -lt 0) { 'left' } else { 'right' })." { param($c) Set-CfgProp $c 'groups' @($order) }
}

function Rename-Group([string]$Old, [string]$New) {
    $New = Resolve-GroupName $New
    if (-not $New -or $New -eq $Old) { return }
    if ($New -eq $script:Ungrouped -or (Test-ReservedGroup $New)) { Log "'$New' is reserved - pick another group name."; return }
    # every project in the group, including hidden ones
    $members = @($script:Projects | Where-Object { (Get-GroupName $_) -eq $Old } | ForEach-Object { $_.Name })
    $allGroups = Get-AllGroups
    if ($script:View -eq "g:$Old") { $script:View = "g:$New"; Save-UiState }   # stay on the renamed tab
    Edit-Config "Renamed group '$Old' to '$New'." {
        param($c)
        foreach ($m in $members) { Set-CfgProp (Get-CfgEntry $c $m) 'group' $New }
        Set-CfgProp $c 'groups' @($allGroups | ForEach-Object { if ($_ -eq $Old) { $New } else { $_ } } | Select-Object -Unique)
        Set-CfgProp $c 'collapsed' @(Get-CfgValue $c 'collapsed' @() | ForEach-Object { if ($_ -eq $Old) { $New } else { $_ } } | Select-Object -Unique)
    }
}

# Deletes the group; its projects become Ungrouped. Nothing on disk besides projects.json changes.
function Remove-Group([string]$Group) {
    $members = @($script:Projects | Where-Object { (Get-GroupName $_) -eq $Group } | ForEach-Object { $_.Name })
    $allGroups = Get-AllGroups
    Edit-Config "Deleted group '$Group' ($($members.Count) project(s) moved to Ungrouped)." {
        param($c)
        foreach ($m in $members) { $e = Get-CfgEntry $c $m; Remove-CfgProp $e 'group'; Remove-CfgProp $e 'order' }
        Set-CfgProp $c 'groups' @($allGroups | Where-Object { $_ -ne $Group })
        Set-CfgProp $c 'collapsed' @(Get-CfgValue $c 'collapsed' @() | Where-Object { $_ -ne $Group })
    }
}

function Remove-GroupFlow([string]$Group) {
    $n = @($script:Projects | Where-Object { (Get-GroupName $_) -eq $Group }).Count
    if ($n -and -not (Confirm-Dc "Delete group '$Group'?`n`nIts $n project(s) move to Ungrouped. No folders are touched." 'Delete group')) { return }
    Remove-Group $Group
}

function Set-ProjectFlag([string]$Name, [string]$Flag, [bool]$On) {
    Edit-Config "$(if ($On) { 'Set' } else { 'Cleared' }) '$Flag' for $Name." {
        param($c)
        $e = Get-CfgEntry $c $Name
        if ($On) { Set-CfgProp $e $Flag $true } else { Remove-CfgProp $e $Flag }
    }
}

# The title on the card (projects.json displayName). The folder itself is never renamed: git
# worktrees, compose project names and VS Code's recent list all point at it.
function Set-DisplayName([string]$Name, [string]$Text) {
    $t = ([string]$Text).Trim()
    if ($t -eq $Name) { $t = '' }
    $cur = ([string](Get-CfgValue (Get-Cfg $Name) 'displayName' '')).Trim()
    if ($t -eq $cur) { Show-Projects; return }
    Edit-Config $(if ($t) { "Renamed $Name to '$t' (display name; the folder keeps its name)." } else { "$Name shows its folder name again." }) {
        param($c)
        $e = Get-CfgEntry $c $Name
        if ($t) { Set-CfgProp $e 'displayName' $t } else { Remove-CfgProp $e 'displayName' }
    }
    Set-Seen $Name
}

# ---- in-place rename of a card title
function Get-ParentElement($el) { if ($el -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent } }
function Get-VisualDescendants($root) {
    $n = [Windows.Media.VisualTreeHelper]::GetChildrenCount($root)
    for ($i = 0; $i -lt $n; $i++) { $c = [Windows.Media.VisualTreeHelper]::GetChild($root, $i); $c; Get-VisualDescendants $c }
}

function Start-Rename([string]$Name) {
    $row = Get-RowByName $Name
    if (-not $row) { return }
    if ($script:EditingName) { Complete-Rename $false '' }
    $script:EditingName = $Name
    $row.IsEditing = $true
    # after the menu / button that started this has let go of the keyboard focus
    [void]$win.Dispatcher.BeginInvoke([Action]{
        $tb = Get-VisualDescendants $ui.ProjectList | Where-Object { $_ -is [Windows.Controls.TextBox] -and $_.Uid -eq 'titlebox' -and [string]$_.Tag -eq $script:EditingName } | Select-Object -First 1
        if ($tb) { $tb.Text = (Get-RowByName $script:EditingName).Title; [void]$tb.Focus(); $tb.SelectAll() }
        else { Complete-Rename $false '' }
    }, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
}

function Complete-Rename([bool]$Commit, [string]$Text) {
    $name = $script:EditingName
    if (-not $name) { return }
    $script:EditingName = $null
    $row = Get-RowByName $name
    if ($row) { $row.IsEditing = $false }
    if ($Commit) { Set-DisplayName $name $Text } else { Show-Projects }
}

# ---- card details
function Switch-Card([string]$Name) {
    $row = $script:LastRows | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $row) { return }
    $row.IsExpanded = -not $row.IsExpanded
    $script:CardExpanded[$Name] = $row.IsExpanded
    if ($row.IsExpanded -and $row.IsProject) { Set-Seen $Name }
}

# ---- Edit details dialog. Save-ProjectEdit is the part without UI (the self-test calls it).
function ConvertTo-ToolList([string]$Text) {
    $t = $Text.Trim()
    if (-not $t) { return , @() }
    try { $j = $t | ConvertFrom-Json } catch { throw "Tools: not valid JSON ($($_.Exception.Message))" }
    $list = @($j)   # a single { ... } is accepted too
    $slugs = @{}
    foreach ($x in $list) {
        if (-not ($x -is [System.Management.Automation.PSCustomObject])) { throw 'Tools: every entry must be an object like { "name": "...", "command": "..." }.' }
        if (-not ([string]$x.name).Trim() -or -not ([string]$x.command).Trim()) { throw 'Tools: every tool needs a "name" and a "command".' }
        $s = Get-DcSlug ([string]$x.name)
        if ($slugs[$s]) { throw "Tools: two tools are called '$($x.name)'." }
        $slugs[$s] = 1
        if ($x.PSObject.Properties['cwd'] -and ([string]$x.cwd) -match '(^|/)\.\.(/|$)') { throw "Tools: the cwd of '$($x.name)' may not contain '..'." }
    }
    , $list
}

# $v: displayName description warning url group mode (strings), pinned hidden openVSCode (bools),
# compose ('auto' | 'on' | 'off'), composeDir services tools (text). Returns '' or an error message.
function Save-ProjectEdit([string]$Name, [hashtable]$v) {
    try {
        $url = ([string]$v.url).Trim()
        if ($url -and $url -notmatch '^https?://\S+$') { return 'URL must start with http:// or https:// and contain no spaces.' }
        $cdir = ([string]$v.composeDir).Trim().Trim('/')
        if ($cdir -match '(^|/)\.\.(/|$)') { return "Compose subfolder may not contain '..'." }
        $tools = ConvertTo-ToolList ([string]$v.tools)
        $services = @(([string]$v.services) -split '[,\s]+' | Where-Object { $_ })
        $group = Resolve-GroupName ([string]$v.group)
        if (Test-ReservedGroup $group) { return "'$group' is reserved - pick another group name." }
        if ($group -eq $script:Ungrouped) { $group = '' }
        $display = ([string]$v.displayName).Trim()
        if ($display -eq $Name) { $display = '' }
        $oldGroup = ([string](Get-CfgValue (Get-Cfg $Name) 'group' '')).Trim()
        $allGroups = Get-AllGroups
    } catch { return $_.Exception.Message }
    $script:EditSaved = $false
    Edit-Config "Saved the details of $Name." {
        param($c)
        $e = Get-CfgEntry $c $Name
        Set-CfgText $e 'displayName' $display
        Set-CfgText $e 'description' ([string]$v.description)
        Set-CfgText $e 'warning' ([string]$v.warning)
        Set-CfgText $e 'url' $url
        Set-CfgText $e 'mode' ([string]$v.mode)
        if ($group -ne $oldGroup) {
            Remove-CfgProp $e 'order'   # lands at the end of the new group
            if ($group) { Set-CfgProp $e 'group' $group } else { Remove-CfgProp $e 'group' }
            if ($group -and $allGroups -notcontains $group) { Set-CfgProp $c 'groups' @(@($allGroups) + $group) }
        }
        if ($v.pinned) { Set-CfgProp $e 'pinned' $true } else { Remove-CfgProp $e 'pinned' }
        if ($v.hidden) { Set-CfgProp $e 'hidden' $true } else { Remove-CfgProp $e 'hidden' }
        if ($v.openVSCode) { Remove-CfgProp $e 'openVSCode' } else { Set-CfgProp $e 'openVSCode' $false }
        switch ([string]$v.compose) { 'on' { Set-CfgProp $e 'compose' $true } 'off' { Set-CfgProp $e 'compose' $false } default { Remove-CfgProp $e 'compose' } }
        Set-CfgText $e 'composeDir' $cdir
        if ($services.Count) { Set-CfgProp $e 'services' $services } else { Remove-CfgProp $e 'services' }
        if ($tools.Count) { Set-CfgProp $e 'tools' $tools } else { Remove-CfgProp $e 'tools' }
        $script:EditSaved = $true
    }
    if (-not $script:EditSaved) { return 'Could not save projects.json - see the log.' }
    Set-Seen $Name
    ''
}

$script:ComposeChoices = @('Automatic (recommended)', 'Always - skip the worktree / shared-name safety check', 'Never')
$script:AnyMode = '(keep whatever mode WSL is in)'

function Import-DialogXaml([string]$File) {
    [xml]$x = Get-Content -Raw -Path (Join-Path $AppDir $File)
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $w.Resources.MergedDictionaries.Add($win.Resources)
    if ($win.IsVisible) { $w.Owner = $win }
    $w.add_SourceInitialized({ try { [DevControl.Native]::DarkTitleBar((New-Object Windows.Interop.WindowInteropHelper $this).Handle) } catch { } })
    $w
}

function Show-EditProject([string]$Name) {
    $p = $script:Projects | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $p) { Log "No project folder '$Name'."; return }
    $cfg = Get-Cfg $Name
    $w = Import-DialogXaml 'EditProject.xaml'
    $f = @{}
    foreach ($n in @('FolderText', 'DetectedText', 'NameBox', 'DescBox', 'GroupBox', 'ModeBox', 'UrlBox', 'WarnBox', 'PinnedBox', 'OpenCodeBox',
                     'HiddenBox', 'AdvancedExp', 'ComposeBox', 'ComposeDirBox', 'ServicesBox', 'ToolsBox', 'SaveBtn', 'ErrorText')) { $f[$n] = $w.FindName($n) }
    $w.Title = "Edit - $(Get-DisplayName $Name)"
    $cpath = ([string](Get-CfgValue $cfg 'path' '')).Trim()
    $f.FolderText.Text = "Folder: " + $(if ($cpath) { "$cpath (projects.json path)" } else { "$(([string]$settings.projectsRoot).TrimEnd('/'))/$Name" })
    $det = @()
    $det += if ($p.Compose) { "compose file $($p.ComposeFile)" + $(if ($p.ComposeName) { " (project '$($p.ComposeName)')" } else { '' }) } else { 'no compose file' }
    if ($p.PSObject.Properties['Worktree'] -and $p.Worktree) { $det += "git worktree of $($p.Parent), branch $($p.Branch)" }
    $f.DetectedText.Text = "Detected: $($det -join '  |  ')"
    $f.NameBox.Text = [string](Get-CfgValue $cfg 'displayName' '')
    $f.DescBox.Text = [string](Get-CfgValue $cfg 'description' '')
    $f.WarnBox.Text = [string](Get-CfgValue $cfg 'warning' '')
    $f.UrlBox.Text = [string](Get-CfgValue $cfg 'url' '')
    $f.GroupBox.ItemsSource = @(Get-AllGroups)
    $f.GroupBox.Text = [string](Get-CfgValue $cfg 'group' '')
    $mode = [string](Get-CfgValue $cfg 'mode' '')
    $modes = @($script:AnyMode) + @(Get-DcModes)
    if ($mode -and $modes -notcontains $mode) { $modes += $mode }   # a mode file that is gone: keep the setting visible
    $f.ModeBox.ItemsSource = $modes
    $f.ModeBox.SelectedItem = if ($mode) { $mode } else { $script:AnyMode }
    $f.ComposeBox.ItemsSource = $script:ComposeChoices
    $f.ComposeBox.SelectedIndex = if ($cfg -and $cfg.PSObject.Properties['compose']) { if ($cfg.compose) { 1 } else { 2 } } else { 0 }
    $f.ComposeDirBox.Text = [string](Get-CfgValue $cfg 'composeDir' '')
    $f.ServicesBox.Text = @(Get-CfgValue $cfg 'services' @()) -join ', '
    $tools = @(Get-CfgValue $cfg 'tools' @() | Where-Object { $_ })
    $f.ToolsBox.Text = if ($tools.Count) { ConvertTo-DcJson $tools } else { '' }
    $f.PinnedBox.IsChecked = [bool](Get-CfgValue $cfg 'pinned' $false)
    $f.HiddenBox.IsChecked = [bool](Get-CfgValue $cfg 'hidden' $false)
    $f.OpenCodeBox.IsChecked = [bool](Get-CfgValue $cfg 'openVSCode' $true)
    $f.AdvancedExp.IsExpanded = $f.ComposeBox.SelectedIndex -ne 0 -or $f.ComposeDirBox.Text -or $f.ServicesBox.Text -or $tools.Count
    $script:EditDlg = @{ Name = $Name; F = $f; Window = $w }
    $f.SaveBtn.add_Click({
        $d = $script:EditDlg; $f = $d.F
        $modeSel = [string]$f.ModeBox.SelectedItem
        $v = @{
            displayName = $f.NameBox.Text; description = $f.DescBox.Text; warning = $f.WarnBox.Text; url = $f.UrlBox.Text
            group = $f.GroupBox.Text; mode = $(if ($modeSel -eq $script:AnyMode) { '' } else { $modeSel })
            pinned = [bool]$f.PinnedBox.IsChecked; hidden = [bool]$f.HiddenBox.IsChecked; openVSCode = [bool]$f.OpenCodeBox.IsChecked
            compose = @('auto', 'on', 'off')[[Math]::Max(0, $f.ComposeBox.SelectedIndex)]
            composeDir = $f.ComposeDirBox.Text; services = $f.ServicesBox.Text; tools = $f.ToolsBox.Text
        }
        $err = Save-ProjectEdit $d.Name $v
        if ($err) { $f.ErrorText.Text = $err } else { $d.Window.DialogResult = $true }
    })
    $w.add_ContentRendered({ [void]$script:EditDlg.F.NameBox.Focus() })
    [void]$w.ShowDialog()
    $script:EditDlg = $null
}

# ---- Projects in group: a checklist of every project, ticked = in the group. Saving goes through
# Set-GroupMembers (the self-test calls that directly).
function Get-GroupPickItems([string]$Group) {
    $items = New-Object 'System.Collections.Generic.List[DevControl.PickItem]'
    # members first, then projects in no group, then the rest; most recent first inside each
    $rank = { param($r) if ($r.Group -eq $Group) { 0 } elseif (-not $r.HasGroup) { 1 } else { 2 } }
    foreach ($r in @($script:AllRows | Where-Object { $_.IsProject } | Sort-Object @{ Expression = { & $rank $_ } }, @{ Expression = { $_.Recent }; Descending = $true })) {
        $it = New-Object DevControl.PickItem
        $it.Name = $r.Name; $it.Title = $r.Title
        $it.IsChecked = $r.Group -eq $Group; $it.WasChecked = $it.IsChecked
        $sub = @()
        if ($r.Group -ne $Group) { $sub += $(if ($r.HasGroup) { "in $($r.Group) - ticking moves it here" } else { 'no group' }) }
        if ($r.IsHiddenRow) { $sub += 'hidden' }
        $age = Format-Age $r.Recent
        if ($age) { $sub += $age }
        $it.Sub = $sub -join $script:Sep
        $items.Add($it)
    }
    , $items
}

function Show-GroupMembers([string]$Group) {
    if (-not $Group -or $script:DialogWin) { return }
    $w = Import-DialogXaml 'GroupMembers.xaml'
    $w.Title = "Projects in $Group"
    $w.FindName('HeadText').Text = "Projects in $Group"
    $all = Get-GroupPickItems $Group
    $script:PickState = @{ All = $all; Group = $Group; Window = $w }
    $list = $w.FindName('Items')
    $list.ItemsSource = $all
    $count = {
        $s = $script:PickState
        $n = @($s.All | Where-Object { $_.IsChecked }).Count
        $s.Window.FindName('CountText').Text = "$n project(s) in $($s.Group)"
    }
    & $count
    $script:PickCount = $count
    # a tick changes the count; checkboxes raise Click, which bubbles to the list
    $list.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{ & $script:PickCount })
    $fb = $w.FindName('FilterBox')
    $fb.add_TextChanged({
        $s = $script:PickState
        $q = $this.Text.Trim()
        $s.Window.FindName('FilterHint').Visibility = if ($this.Text) { 'Collapsed' } else { 'Visible' }
        $s.Window.FindName('Items').ItemsSource = if ($q) {
            , @($s.All | Where-Object { $_.Title.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        } else { $s.All }
    })
    $w.FindName('SaveBtn').add_Click({ [Windows.Window]::GetWindow($this).DialogResult = $true })
    $w.add_ContentRendered({ [void]$this.FindName('FilterBox').Focus() })
    $script:DialogWin = $w
    try { $ok = $w.ShowDialog() } finally { $script:DialogWin = $null }
    if ($ok) { Set-GroupMembers $Group @($all | Where-Object { $_.IsChecked } | ForEach-Object { $_.Name }) }
    $script:PickState = $null
}

# Small dark text prompt (WPF has no InputBox). Returns the text or $null.
function Read-DcText([string]$Title, [string]$Prompt, [string]$Default = '', $Owner = $null) {
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
    if ($Owner) { $w.Owner = $Owner } elseif ($win.IsVisible) { $w.Owner = $win }
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
            'edit'     { Show-EditProject $a[1] }
            'rename'   { Start-Rename $a[1] }
            'moveto'   { Move-ProjectTo $a[1] $a[2] }
            'newgroup' { New-GroupFlow $a[1] }
            'members'  { Show-GroupMembers $a[1] }
            'pin'      { Set-ProjectFlag $a[1] 'pinned' $true }
            'unpin'    { Set-ProjectFlag $a[1] 'pinned' $false }
            'hide'     { Set-ProjectFlag $a[1] 'hidden' $true }
            'unhide'   { Set-ProjectFlag $a[1] 'hidden' $false }
            'seq'      { Start-Sequence $a[1] $a[2] }
            'copypath' { $r = Get-RowByName $a[1]; if ($r) { [Windows.Clipboard]::SetText($r.Folder); Log "Copied $($r.Folder)" } }
            'grename'  {
                $n = Read-DcText 'Rename group' "New name for group '$($a[1])':" $a[1]
                if ($n) { Rename-Group $a[1] $n }
            }
            'gup'      { Move-GroupStep $a[1] -1 }
            'gdown'    { Move-GroupStep $a[1] 1 }
            'gdelete'  { Remove-GroupFlow $a[1] }
            'refresh'  { Update-Projects; Update-Runtime }
            'stopall'  { Stop-AllContainersFlow }
            'editjson' {
                $p = Get-DcConfigPath
                if (Test-Path $p) { Start-Process notepad.exe -ArgumentList "`"$p`"" } else { Log "projects.json not found: $p" }
            }
            'reload'   { Import-Config; Update-Projects }
            'seenall'  {
                if ($script:Seen) { foreach ($p in $script:Projects) { [void]$script:Seen.Add([string]$p.Name) }; Save-UiState }
                Show-Projects
            }
            'log'      { Set-LogOpen (-not $script:LogOpen) }
        }
    } catch { Log "Menu action failed: $($_.Exception.Message)" }
}

# The group picker: what the group label on a card opens, and the card menu's "Group" submenu.
# The current group is ticked; picking another moves the project there.
function Add-GroupPickItems($Items, [string]$Name) {
    $row = Get-RowByName $Name
    foreach ($g in @(Get-AllGroups)) {
        $mi = New-DcMenuItem $g @('moveto', $Name, $g)
        $mi.IsChecked = $row -and $row.Group -eq $g
        [void]$Items.Add($mi)
    }
    $none = New-DcMenuItem 'No group' @('moveto', $Name, '')
    $none.IsChecked = $row -and -not $row.HasGroup
    [void]$Items.Add($none)
    [void]$Items.Add((New-Object Windows.Controls.Separator))
    [void]$Items.Add((New-DcMenuItem 'New group...' @('newgroup', $Name)))
}

function New-GroupPickMenu([string]$Name) {
    $m = New-Object Windows.Controls.ContextMenu
    Add-GroupPickItems $m.Items $Name
    $m
}

function New-ProjectMenu([string]$Name) {
    $row = Get-RowByName $Name
    $m = New-Object Windows.Controls.ContextMenu
    if (-not $row) { return $m }
    [void]$m.Items.Add((New-DcMenuItem 'Edit details...' @('edit', $Name)))
    [void]$m.Items.Add((New-DcMenuItem 'Rename...' @('rename', $Name)))
    $to = New-DcMenuItem 'Group' $null
    Add-GroupPickItems $to.Items $Name
    [void]$m.Items.Add($to)
    if ($row.IsPinned) { [void]$m.Items.Add((New-DcMenuItem 'Unpin' @('unpin', $Name))) } else { [void]$m.Items.Add((New-DcMenuItem 'Pin to top' @('pin', $Name))) }
    if ($row.IsHiddenRow) { [void]$m.Items.Add((New-DcMenuItem 'Unhide' @('unhide', $Name))) } else { [void]$m.Items.Add((New-DcMenuItem 'Hide' @('hide', $Name))) }
    [void]$m.Items.Add((New-Object Windows.Controls.Separator))
    [void]$m.Items.Add((New-DcMenuItem 'Open in Linux VS Code' @('seq', 'code', $Name) $row.CanCode))
    [void]$m.Items.Add((New-DcMenuItem 'Open in Windows VS Code' @('seq', 'codewin', $Name) $row.CanCode))
    [void]$m.Items.Add((New-DcMenuItem 'Copy folder path' @('copypath', $Name)))
    $m
}

# A group tab's menu (right-click on the tab, or ... next to Add projects).
function New-GroupMenu([string]$Group) {
    $m = New-Object Windows.Controls.ContextMenu
    $groups = @(Get-AllGroups)
    $i = [array]::IndexOf($groups, $Group)
    [void]$m.Items.Add((New-DcMenuItem 'Add or remove projects...' @('members', $Group)))
    [void]$m.Items.Add((New-DcMenuItem 'Rename group...' @('grename', $Group)))
    [void]$m.Items.Add((New-DcMenuItem 'Move left' @('gup', $Group) ($i -gt 0)))
    [void]$m.Items.Add((New-DcMenuItem 'Move right' @('gdown', $Group) ($i -ge 0 -and $i -lt $groups.Count - 1)))
    [void]$m.Items.Add((New-Object Windows.Controls.Separator))
    [void]$m.Items.Add((New-DcMenuItem 'Delete group (projects keep running, become ungrouped)' @('gdelete', $Group)))
    $m
}

# The header's ... menu: things used rarely enough not to need a button.
function New-MoreMenu {
    $run = $script:State.Running -eq $true
    $idle = Get-Idle
    $m = New-Object Windows.Controls.ContextMenu
    [void]$m.Items.Add((New-DcMenuItem 'Refresh now' @('refresh') ($idle -and $run)))
    [void]$m.Items.Add((New-DcMenuItem "Stop all containers ($($script:Containers.Count))" @('stopall') ($idle -and $run -and $script:Containers.Count -gt 0)))
    [void]$m.Items.Add((New-Object Windows.Controls.Separator))
    [void]$m.Items.Add((New-DcMenuItem 'Edit projects.json in Notepad' @('editjson')))
    [void]$m.Items.Add((New-DcMenuItem 'Reload projects.json' @('reload')))
    [void]$m.Items.Add((New-DcMenuItem 'Clear all New badges' @('seenall') ([bool]@($script:AllRows | Where-Object { $_.IsNew }).Count)))
    [void]$m.Items.Add((New-Object Windows.Controls.Separator))
    [void]$m.Items.Add((New-DcMenuItem $(if ($script:LogOpen) { 'Hide activity log' } else { 'Show activity log' }) @('log')))
    $m
}

function Open-Menu($Menu, $Target) {
    $Menu.PlacementTarget = $Target
    $Menu.Placement = if ($Target -is [Windows.Controls.Button]) { 'Bottom' } else { 'MousePoint' }
    $Menu.IsOpen = $true
    $script:LastMenu = $Menu
}

# ---- project list events: click a card header to open it, right-click for its menu, drag it onto a
# tab, rename in place.
function Get-RowContext($el) {
    while ($el) {
        if ($el -is [Windows.FrameworkElement] -and $el.DataContext -is [DevControl.ProjectRow]) { return $el.DataContext }
        $el = Get-ParentElement $el
    }
    $null
}
function Test-InButton($el) {
    while ($el) {
        if ($el -is [Windows.Controls.Primitives.ButtonBase] -or $el -is [Windows.Controls.Primitives.ScrollBar] -or $el -is [Windows.Controls.Primitives.TextBoxBase]) { return $true }
        if ($el -is [Windows.Controls.ItemsControl] -and $el -eq $ui.ProjectList) { return $false }
        $el = Get-ParentElement $el
    }
    $false
}
function Get-HeaderRow($el) {
    while ($el -and $el -ne $ui.ProjectList) {
        if ($el -is [Windows.FrameworkElement] -and $el.Uid -eq 'hdr') { if ($el.DataContext -is [DevControl.ProjectRow]) { return $el.DataContext } else { return $null } }
        $el = Get-ParentElement $el
    }
    $null
}

$ui.ProjectList.add_MouseLeftButtonUp({
    param($s, $e)
    $script:RowDrag = $null
    if (Test-InButton $e.OriginalSource) { return }
    $row = Get-HeaderRow $e.OriginalSource
    if ($row) { Switch-Card $row.Name }
})
$ui.ProjectList.add_MouseRightButtonUp({
    param($s, $e)
    if (Test-InButton $e.OriginalSource) { return }
    $ctx = Get-RowContext $e.OriginalSource
    if ($ctx -and $ctx.IsProject) { Open-Menu (New-ProjectMenu $ctx.Name) $ui.ProjectList; $e.Handled = $true }
})
$ui.ProjectList.add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $script:RowDrag = $null
    if (Test-InButton $e.OriginalSource) { return }
    $row = Get-HeaderRow $e.OriginalSource
    if ($row -and $row.IsProject -and -not $row.IsEditing) { $script:RowDrag = @{ Name = $row.Name; Start = $e.GetPosition($win) } }
})
$ui.ProjectList.add_PreviewMouseMove({
    param($s, $e)
    $d = $script:RowDrag
    if (-not $d -or $e.LeftButton -ne 'Pressed') { return }
    $p = $e.GetPosition($win)
    if ([Math]::Abs($p.X - $d.Start.X) -lt 8 -and [Math]::Abs($p.Y - $d.Start.Y) -lt 8) { return }
    $script:RowDrag = $null
    $script:Dragging = $true   # no list rebuild while the row is held
    try { [void][Windows.DragDrop]::DoDragDrop($s, (New-Object Windows.DataObject('DevControlProject', $d.Name)), 'Move') }
    finally { $script:Dragging = $false; Clear-DropHot; Show-Projects }
})
$ui.ProjectList.add_PreviewKeyDown({
    param($s, $e)
    $tb = $e.OriginalSource
    if (-not ($tb -is [Windows.Controls.TextBox] -and $tb.Uid -eq 'titlebox')) { return }
    if ($e.Key -eq 'Return') { $e.Handled = $true; Complete-Rename $true $tb.Text }
    elseif ($e.Key -eq 'Escape') { $e.Handled = $true; Complete-Rename $false '' }
})
$ui.ProjectList.AddHandler([Windows.UIElement]::LostKeyboardFocusEvent, [Windows.Input.KeyboardFocusChangedEventHandler]{
    param($s, $e)
    $tb = $e.OriginalSource
    if ($tb -is [Windows.Controls.TextBox] -and $tb.Uid -eq 'titlebox' -and [string]$tb.Tag -eq $script:EditingName) { Complete-Rename $true $tb.Text }
})

# ---- tabs: click = view, right-click a group tab = its menu, drop a project = move it there.
function Get-TabTarget($el) {
    while ($el -and $el -ne $ui.ViewTabs) {
        if (($el -is [Windows.Controls.RadioButton] -or $el -is [Windows.Controls.Button]) -and $el.Tag) { return $el }
        $el = Get-ParentElement $el
    }
    $null
}
# What dropping a project on a tab does ('' = nothing).
function Get-DropAction([string]$Key) {
    if ($Key.StartsWith('g:') -or $Key -in @('ungrouped', 'hidden', 'newgroup')) { return $Key }
    ''
}
function Invoke-TabDrop([string]$Name, [string]$Key) {
    if (-not $Name) { return }
    if ($Key.StartsWith('g:')) { Move-ProjectTo $Name $Key.Substring(2) }
    elseif ($Key -eq 'ungrouped') { Move-ProjectTo $Name '' }
    elseif ($Key -eq 'hidden') { Set-ProjectFlag $Name 'hidden' $true }
    elseif ($Key -eq 'newgroup') { New-GroupFlow $Name }
}
function Clear-DropHot {
    if ($script:DropHot) { $script:DropHot.BorderBrush = [Windows.Media.Brushes]::Transparent; $script:DropHot = $null }
}

$ui.ViewTabs.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent, [Windows.RoutedEventHandler]{
    param($s, $e)
    if ($e.OriginalSource -is [Windows.Controls.RadioButton]) { Set-View ([string]$e.OriginalSource.Tag) }
})
$ui.ViewTabs.AddHandler([Windows.Controls.Button]::ClickEvent, [Windows.RoutedEventHandler]{
    param($s, $e)
    if ($e.OriginalSource -is [Windows.Controls.Button] -and [string]$e.OriginalSource.Tag -eq 'newgroup') { New-GroupFlow }
})
$ui.ViewTabs.add_PreviewMouseRightButtonUp({
    param($s, $e)
    $t = Get-TabTarget $e.OriginalSource
    if ($t -and ([string]$t.Tag).StartsWith('g:')) { Open-Menu (New-GroupMenu ([string]$t.Tag).Substring(2)) $ui.ViewTabs; $e.Handled = $true }
})
$ui.ViewTabs.add_DragOver({
    param($s, $e)
    $e.Handled = $true
    $t = Get-TabTarget $e.OriginalSource
    $act = if ($t -and $e.Data.GetDataPresent('DevControlProject')) { Get-DropAction ([string]$t.Tag) } else { '' }
    $e.Effects = if ($act) { 'Move' } else { 'None' }
    if ($script:DropHot -ne $t) { Clear-DropHot }
    if ($act -and $t) { $t.BorderBrush = Get-Brush '#3B82F6'; $script:DropHot = $t }
})
$ui.ViewTabs.add_DragLeave({ Clear-DropHot })
$ui.ViewTabs.add_Drop({
    param($s, $e)
    $e.Handled = $true
    Clear-DropHot
    $t = Get-TabTarget $e.OriginalSource
    if (-not $t -or -not $e.Data.GetDataPresent('DevControlProject')) { return }
    $script:Dragging = $false   # let the move redraw the list
    Invoke-TabDrop ([string]$e.Data.GetData('DevControlProject')) ([string]$t.Tag)
})

$ui.AddToGroupBtn.add_Click({ if ($script:View.StartsWith('g:')) { Show-GroupMembers $script:View.Substring(2) } })
$ui.EmptyAddBtn.add_Click({ if ($script:View.StartsWith('g:')) { Show-GroupMembers $script:View.Substring(2) } })
$ui.GroupMenuBtn.add_Click({ if ($script:View.StartsWith('g:')) { Open-Menu (New-GroupMenu $script:View.Substring(2)) $ui.GroupMenuBtn } })
$ui.SortBtn.add_Click({
    $script:Sort = if ($script:Sort -eq 'recent') { 'name' } else { 'recent' }
    Save-UiState
    Show-Projects
})

# ---- search: filters the current tab as you type. Up / Down pick a row, Enter opens it in VS Code,
# Ctrl+Enter runs or stops it, Esc clears. Ctrl+F (or /) jumps here from anywhere in the window.
function Move-Active([int]$Delta) {
    $rows = @($script:LastRows | Where-Object { $_.IsProject })
    if (-not $rows.Count) { return }
    $i = -1
    for ($k = 0; $k -lt $rows.Count; $k++) { if ($rows[$k].Name -eq $script:ActiveName) { $i = $k } }
    $i = if ($i -lt 0) { if ($Delta -gt 0) { 0 } else { $rows.Count - 1 } } else { [Math]::Max(0, [Math]::Min($rows.Count - 1, $i + $Delta)) }
    $script:ActiveName = $rows[$i].Name
    foreach ($r in $script:LastRows) { $r.IsActive = $r.Name -eq $script:ActiveName }
    $c = $ui.ProjectList.ItemContainerGenerator.ContainerFromItem($rows[$i])
    if ($c) { $c.BringIntoView() }
}

function Invoke-Active([bool]$Primary) {
    $r = @($script:LastRows | Where-Object { $_.IsProject -and $_.Name -eq $script:ActiveName })[0]
    if (-not $r) { return }
    if ($Primary) {
        if ($r.ShowPrimary -and $r.PrimaryEnabled) { Start-Sequence $r.PrimaryUid $r.Name } else { Log "$($r.Title): nothing to run or stop right now." }
    } elseif ($r.CanCode) { Start-Sequence 'codedef' $r.Name }
}

$ui.SearchBox.add_TextChanged({
    $script:Search = $ui.SearchBox.Text
    $script:ActiveName = $null   # the best match gets the highlight
    $ui.SearchHint.Visibility = if ($ui.SearchBox.Text) { 'Collapsed' } else { 'Visible' }
    $ui.SearchClearBtn.Visibility = if ($ui.SearchBox.Text) { 'Visible' } else { 'Collapsed' }
    Show-Projects
})
$ui.SearchBox.add_PreviewKeyDown({
    param($s, $e)
    switch ([string]$e.Key) {
        'Down'   { $e.Handled = $true; Move-Active 1 }
        'Up'     { $e.Handled = $true; Move-Active -1 }
        'Return' { $e.Handled = $true; Invoke-Active ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) }
        'Escape' {
            $e.Handled = $true
            if ($ui.SearchBox.Text) { $ui.SearchBox.Text = '' }
            else { $script:ActiveName = $null; foreach ($r in $script:LastRows) { $r.IsActive = $false } }
        }
    }
})
$ui.SearchBox.add_GotKeyboardFocus({ $ui.SearchFrame.BorderBrush = Get-Brush '#3B82F6' })
$ui.SearchBox.add_LostKeyboardFocus({ $ui.SearchFrame.BorderBrush = Get-Brush '#2E3138' })
$ui.SearchClearBtn.add_Click({ $ui.SearchBox.Text = ''; [void]$ui.SearchBox.Focus() })
$win.add_PreviewKeyDown({
    param($s, $e)
    $ctrl = [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control
    $inText = [Windows.Input.Keyboard]::FocusedElement -is [Windows.Controls.Primitives.TextBoxBase]
    if (($ctrl -and $e.Key -eq 'F') -or (-not $inText -and $e.Key -eq 'OemQuestion')) {
        $e.Handled = $true; [void]$ui.SearchBox.Focus(); $ui.SearchBox.SelectAll()
    }
})

# ---- activity log: one line at the bottom; click it to open the full log.
function Set-LogOpen([bool]$Open) {
    $script:LogOpen = $Open
    $ui.LogPanel.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' }
    $ui.LastLogText.Visibility = if ($Open) { 'Hidden' } else { 'Visible' }
    $ui.LogToggleText.Text = [string][char]$(if ($Open) { 0xE70D } else { 0xE70E })
    if ($Open) { $ui.LogBox.ScrollToEnd() }
    Save-UiState
}
$ui.LogBar.add_MouseLeftButtonUp({ Set-LogOpen (-not $script:LogOpen) })

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

# Tray "Run project": pinned projects, then the most recently used ones (up to 8 in all) that have
# something to run. Rebuilt only when that list changes.
function Update-TrayRunMenu {
    if (-not $script:TrayItems.Run) { return }
    $cand = @($script:AllRows | Where-Object { $_.IsProject -and -not $_.IsHiddenRow -and ($_.ShowRun -or $_.IsPinned) })
    $pick = @(@($cand | Where-Object { $_.IsPinned } | Sort-Object Title) + @($cand | Where-Object { -not $_.IsPinned } | Sort-Object Recent -Descending) | Select-Object -First 8)
    $key = @($pick | ForEach-Object { "$($_.Name)=$($_.Title)" }) -join '|'
    if ($key -eq $script:TrayKey) { return }
    $script:TrayKey = $key
    $script:TrayItems.Run.DropDownItems.Clear()
    $pinnedDone = $false
    foreach ($r in $pick) {
        if (-not $r.IsPinned -and -not $pinnedDone) {
            $pinnedDone = $true
            if ($script:TrayItems.Run.DropDownItems.Count) { [void]$script:TrayItems.Run.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
        }
        $it = New-Object System.Windows.Forms.ToolStripMenuItem $r.Title
        $it.Tag = $r.Name
        $it.add_Click({ param($s, $e) Start-Sequence 'run' ([string]$s.Tag) })
        [void]$script:TrayItems.Run.DropDownItems.Add($it)
    }
    $script:TrayItems.Run.Visible = $pick.Count -gt 0
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
    $script:TrayItems.CodeOpen = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Linux VS Code'
    $script:TrayItems.CodeOpen.add_Click({ Open-EmptyCode 'linux' })
    $script:TrayItems.CodeOpenWin = New-Object System.Windows.Forms.ToolStripMenuItem 'Open Windows VS Code'
    $script:TrayItems.CodeOpenWin.add_Click({ Open-EmptyCode 'windows' })
    $script:TrayItems.CodeQuit = New-Object System.Windows.Forms.ToolStripMenuItem 'Quit Linux VS Code'
    $script:TrayItems.CodeQuit.add_Click({ Stop-VSCodeFlow })
    $script:TrayItems.Exit = New-Object System.Windows.Forms.ToolStripMenuItem 'Exit'
    $script:TrayItems.Exit.add_Click({ Exit-App })
    [void]$menu.Items.Add($script:TrayItems.Open)
    [void]$menu.Items.Add($script:TrayItems.Run)
    [void]$menu.Items.Add($script:TrayItems.Start)
    [void]$menu.Items.Add($script:TrayItems.Stop)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($script:TrayItems.CodeOpen)
    [void]$menu.Items.Add($script:TrayItems.CodeOpenWin)
    [void]$menu.Items.Add($script:TrayItems.CodeQuit)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($script:TrayItems.Exit)
    $script:Tray.ContextMenuStrip = $menu
    $script:Tray.add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Main } })
    $script:Tray.Visible = $true
}

# ---------------------------------------------------------------- event wiring

$ui.ModeCombo.ItemsSource = @(Get-DcModes)
$ui.ModeCombo.add_SelectionChanged({ Update-Enablement })   # Start WSL <-> Switch to <mode>
$ui.StartBtn.add_Click({ Start-WslFlow ([string]$ui.ModeCombo.SelectedItem) })
$ui.StopWslBtn.add_Click({ Stop-WslFlow })
$ui.CodeOpenBtn.add_Click({ Open-EmptyCode 'linux' })
$ui.CodeOpenWinBtn.add_Click({ Open-EmptyCode 'windows' })
$ui.CodeQuitBtn.add_Click({ Stop-VSCodeFlow })
$ui.MoreBtn.add_Click({ Open-Menu (New-MoreMenu) $ui.MoreBtn })

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
        'codewin' { Start-Sequence 'codewin' $tag }
        'codedef' { Start-Sequence 'codedef' $tag }
        'open'    {
            $u = [string](Get-CfgValue (Get-Cfg $tag) 'url' '')
            if ($u -match '^https?://') { Start-Process $u; Set-Used $tag; Log "Opened $u" } else { Log "No valid url for $tag" }
        }
        'child'   { Stop-Child $tag }
        'menu'    { Open-Menu (New-ProjectMenu $tag) $b }
        'group'   { Open-Menu (New-GroupPickMenu $tag) $b }
        'toggle'  { Switch-Card $tag }
        'rename'  { Start-Rename $tag }
        'edit'    { Show-EditProject $tag }
    }
}
$ui.ProjectList.AddHandler([Windows.Controls.Button]::ClickEvent, $projectClick)

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
Set-LogOpen $script:LogOpen
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
