# Dev Control - CLAUDE.md

Developer guide for Claude sessions working on Dev Control: a Windows desktop app (Windows
PowerShell 5.1 + WPF, tiny C# launcher) that manages a WSL2 dev environment from the Windows side.
Features, settings and the `projects.json` schema are in `README.md`; fix history in `docs/fixes.md`.

Paths below are relative to this folder (`devcontrol/` in the repo). The app is installed to and
**runs from** `%LOCALAPPDATA%\Programs\DevControl` (default of `Deploy.ps1 -Destination`); runtime
data and logs are in `%LOCALAPPDATA%\DevControl`.

## Session-start checklist
1. Edit `src/`, `modes/`, `Deploy.ps1`, etc. here. Never edit the installed copy directly: it is
   overwritten on deploy (except `settings.json` / `projects.json` / `modes\*`, which are user files).
2. After changes: static checks (below), then `Deploy.ps1`, then - only if the user agrees -
   `tests/Run-SelfTest.ps1` (WSL must be running). The self-test opens real VS Code windows and
   brings a compose project up: never run it or launch the app while the user is working unless asked.
3. **Never run `wsl --shutdown`, `wsl --terminate`, or click-test Stop WSL / a mode switch / Quit
   VS Code for real.** Claude may itself be running inside WSL (e.g. in Linux VS Code's extension host
   or a WSL terminal), so any of them kills its own session. Those paths are covered by the self-test
   with "No" answers plus the manual checklist in `README.md`.

## Static checks (safe, no WSL, no UI)
```powershell
Get-ChildItem -Recurse -Include *.ps1 | % { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e); if ($e) { $_.FullName; $e } }
```
`Deploy.ps1` refuses non-ASCII `.ps1` / `.xaml`. A XAML load check with `[Windows.Markup.XamlReader]::Parse`
on `src/MainWindow.xaml` (in an STA PowerShell, without showing the window) is also safe.

## Hard rules
- Any `wsl.exe` call that executes something in Linux boots WSL. All such calls go through
  `Invoke-DcLinux` (guarded by `Test-DcWslRunning`). Only `Start-DcWslBoot` boots on purpose;
  `Open-DcVSCode` boots too (VS Code runs in / connects to Linux), so the VS Code button runs a `code`
  sequence that starts WSL in the project's mode first.
- Never call `wsl.exe` just to learn something about WSL configuration: the default distro comes from
  the registry (`HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss` `DefaultDistribution` >
  `<guid>\DistributionName`, see `Get-DcDefaultDistro`). `wsl.exe --list --running --quiet` is the only
  query (`QUERY` in `wsl-calls.log`).
- VS Code is the LINUX build by default (`codeFlavor: linux`): `Open-DcVSCode` runs
  `$HOME/.local/bin/code-linux` in WSL (installed by the repo's Linux setup, not by Dev Control; exit
  127 = missing, reported with a hint). It must add `--ozone-platform=wayland --disable-gpu` (without
  them the WSLg window glitches and the mouse is offset) and MUST export `DONT_PROMPT_WSL_INSTALL=1`:
  without it VS Code's `bin/code` waits on a `[y/N]` stdin prompt, the detached launch hangs and the
  self-test fails `VS Code launched: timed out`. Linux VS Code windows CLOSE on WSL shutdown rather than
  disconnect. `"codeFlavor": "windows"` uses Windows VS Code `--remote wsl+<distro>`.
- Every external process from the app goes through `Invoke-DcProcess` / `Start-DcDetached`
  (CreateNoWindow). The app has no console, so a plain `& exe` pops a console window.
- `.ps1` and `.xaml` files must be ASCII-only (PS 5.1 reads BOM-less files as ANSI). `Deploy.ps1`
  enforces this.
- Linux scripts are passed base64-encoded (`bash -lc "echo <b64> | base64 -d | bash"`) - no quoting
  issues with paths containing spaces. Paths inside scripts go through `ConvertTo-DcBashLiteral`.
- `projectsRoot` has no default. Use `Get-DcProjectsRoot` (throws the "set projectsRoot in
  settings.json" message) in Core; the UI shows that message and skips project listing when it is empty.
- `modesDir` defaults to `modes` next to the app; `%VARS%` are expanded and relative paths resolve
  against `$script:DcAppDir` (`Resolve-DcAppPath`). Mode matching ignores `#`/`;` comment lines.
- Project discovery is folder-driven: EVERY directory under `projectsRoot` is listed, whether or not it
  has a compose file. `projects.json` only adds metadata; a folder with no entry lands in group `New`
  (rank -1, above everything). Hide noise with the card menu's Hide, not by deleting entries.
  Exception: an entry with `path` is listed from that folder (Linux path, or Windows path via `/mnt/<drive>`);
  every folder path goes through `Get-DcProjectDir`, never `"$root/$Project"`. A Windows-path project opens
  in Windows VS Code locally by default (`Get-DcProjectFlavor`).
- Compose safety: worktrees and folders sharing a compose `name:` with another folder get no compose
  unless `"compose": true` (`Get-ComposePolicy`); `Invoke-DcCompose` refuses `up`/`restart` when the
  compose name already has containers from another folder.
- VS Code inside WSL is found by `comm == 'code'` and reduced to ROOT processes (parent is not itself a
  `code` process) - one root per application instance; `Get-DcRuntime` reports the count (`V` line) and
  `Stop-DcVSCode` SIGTERMs those roots, SIGKILLing survivors after 20 s. The pid list must be
  space-joined (`tr '\n' ' '`) or the `case " $pids " in *" $ppid "*` parent test never matches and
  every child looks like a root.
- The app WRITES `projects.json` (arrangement edits) via `Edit-Config` > `Save-DcConfigFile` (custom
  `ConvertTo-DcJson` pretty-printer, atomic write, `.bak`). Always re-read from disk inside the edit;
  never write the cached copy. `DEVCONTROL_PROJECTS_JSON` redirects the file (the self-test uses a
  generated temp file; its `.bak` goes next to it).
- Menu items carry their action in `Tag` and share `Invoke-MenuAction`: scriptblock closures
  (`GetNewClosure`) can't see this script's functions.
- PS 5.1 gotchas: a function returning ONE pscustomobject has no `.Count` (wrap in `@()` or return
  `, @(...)`); `New-Object T($list)` spreads a 1-item list into ctor args - use `[T]::new($list)`.
  A here-string does NOT include the newline before its `'@`, so concatenating bash fragments
  (`@'...done'@ + $snippet`) glues `done` onto the next command - every shared snippet starts with a
  blank line. No `&&`, `??`, ternary. `"$var:"` inside a double-quoted string is a scope-qualified
  variable - write `` "$var`:" ``.
- The self-test must never depend on real projects: it creates `zz-devcontrol-selftest*` fixture
  folders in `projectsRoot` and a generated `projects.json`, and removes them at the end. Don't
  compose-up real projects in tests.

## Tool Registry

### Deploy.ps1
- Path: `Deploy.ps1` (runs on Windows) - Fix log: `docs/fixes.md`
- Purpose: ASCII check; copy `src/*` to the install folder; seed `settings.json` once from
  `settings.default.json` (distro / projectsRoot / modesDir filled in; later runs only fill empty
  `distro` / `projectsRoot` when passed); seed `projects.json` once from `projects.example.json`; copy
  missing `modes/*.wslconfig`; build via `Install.ps1` when `-Build` or the exe is missing; `-Sign`
  creates/reuses + trusts the `CN=KD Dev Tools` cert and signs; Start Menu + Desktop shortcuts.
- Invocation: `powershell -NoProfile -ExecutionPolicy Bypass -File devcontrol\Deploy.ps1 [-Destination <dir>] [-Distro <name>] [-ProjectsRoot /home/<you>/projects] [-Build] [-Sign] [-NoDesktopShortcut]`
- From WSL: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w devcontrol/Deploy.ps1)"`
- Safe while the app runs: icons are swapped via temp files (kept if locked); the exe is compiled to
  `%TEMP%\devcontrol-build` and swapped in (clear error if locked). A running instance keeps the old
  code until restarted (Deploy warns).

### Install.ps1
- Path: `src/Install.ps1` (build step, runs from the install folder; called by Deploy.ps1) - Fix log: `docs/fixes.md` (FIX-001 icon locked, FIX-002 SmartScreen)
- Purpose: draw `DevControl.ico/.png`, compile `DevControl.exe` with
  `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:`, sign it with the
  `CN=KD Dev Tools` cert if present. `-SignOnly` re-signs the existing exe.

### Uninstall-DevControl.ps1
- Path: `Uninstall-DevControl.ps1`
- Purpose: close a running instance, back up `settings.json` / `projects.json` to
  `%LOCALAPPDATA%\DevControl\uninstall-backup-<date>\`, remove shortcuts pointing into the install
  folder and the folder itself. `-RemoveCertificate` removes the cert from CurrentUser My/Root/
  TrustedPublisher; `-RemoveData` removes logs (keeps backups). `-Destination` for other install folders.

### tests/Run-SelfTest.ps1
- Path: `tests/Run-SelfTest.ps1`
- Purpose: launches the installed app with `-SelfTest` (timeout 15 min), prints PASS/FAIL lines from
  `%LOCALAPPDATA%\DevControl\selftest.log`; exit code = failures. The test clicks every button via UI
  Automation (project Run/Stop/Restart, nested container/tool Stop, pinned panel, tray, arrangement
  menus, drag/drop), answers confirms (always No for Stop WSL / mode switch / Quit VS Code), checks
  classification (worktree, compose:false, compose-name clash, services subset, hidden, New) and the
  compose guard, simulates "WSL stopped" via `DEVCONTROL_FAKE_STOPPED=1` and asserts no Linux calls
  from its own PID.
- Needs: WSL running, `projectsRoot` set, at least two modes.
- Side effects: pulls `alpine`, composes the fixture project up/down, opens the
  `zz-devcontrol-selftest-mode` fixture AND an empty window in VS Code (close them after); the
  stop-all step is skipped if non-test containers are running.
- If it prints "no fresh selftest.log", the app crashed at startup - run
  `powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%LOCALAPPDATA%\Programs\DevControl\DevControl.ps1" -SelfTest` to see the error.

### Running / inspecting the installed app (only when the user asks)
- Launch like a double-click: `explorer.exe "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Dev Control.lnk"`.
- Close it: `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -like '*DevControl.ps1*' } | % { Stop-Process -Id $_.ProcessId }`
- Core functions ad hoc (Windows-only ones are safe; anything calling `Invoke-DcLinux` needs WSL running):
  `cd $env:LOCALAPPDATA\Programs\DevControl; . .\Core.ps1; Get-DcSettings; Get-DcStatus`

## Key file map
- `src/Core.ps1` - settings, WSL state, modes, lifecycle, project listing (worktrees, compose names),
  compose + collision guard, runtime (containers + tools), tools, projects.json, logging
- `src/DevControl.ps1` - UI wiring, runspace-pool job runner (`Start-Bg` / `On-Tick`), lifecycle
  deferral, tray, project Run/Stop/Restart/code sequence runner, compose policy (`Get-ComposePolicy`), grouping
- `src/MainWindow.xaml` - layout/styles; item-template buttons use `Uid` = action
  (run/stop/restart/open/code/child), `Tag` = project name or `c:<id>` / `t:<slug>/<tool>`; project list
  grouped via ListCollectionView + Expander GroupStyle
- `src/SelfTest.ps1` - the `-SelfTest` driver (fixtures, steps, cleanup)
- `modes/*.wslconfig` - example modes, copied to `<install>\modes` only when missing
- Runtime logs: `%LOCALAPPDATA%\DevControl\app.log`, `wsl-calls.log`, `selftest.log`

## Environment assumptions
- Windows 10/11, Windows PowerShell 5.1, WSL2 with systemd; Docker Engine native in the distro
  (not Docker Desktop), Compose v2.
- `vmmemWSL` WorkingSet64 is readable without admin.
- A `bash -l` login shell may print harmless `.profile` errors on stderr; output filters drop
  `.profile: line` noise.
