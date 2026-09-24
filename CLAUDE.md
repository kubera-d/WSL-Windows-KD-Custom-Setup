# WSL Windows KD Custom Setup - CLAUDE.md

Public repo: Linux VS Code under WSLg as the everyday editor on Windows 11, plus WSLg fixes and the
Dev Control app. Read `README.md` (user view) and `docs/how-it-works.md` (the why) first.
Dev Control has its own developer guide: `devcontrol/CLAUDE.md`.

## Hard rules
- **Public repo: no personal data.** No usernames, home paths (`C:\Users\<name>`, `/home/<name>`),
  hostnames, emails, project names from the maintainer's machine, tokens, cert thumbprints. Paths are
  detected at install time (`Get-LinuxHome`, `[Environment]::GetFolderPath`, `%LOCALAPPDATA%`). Per-user
  files (`settings.json`, `projects.json`, logs) are git-ignored. `.env*`, keys, credentials and
  `*.jsonl` transcripts are ignored too. A pre-commit hook (`tools/check-public.sh`, enabled with
  `git config core.hooksPath tools/hooks`) blocks private-looking files, API-key patterns and the words in
  the local, never-committed `.git/private-words` (maintainer's usernames, paths, project folder names).
  Never bypass it with `--no-verify`.
- **Never run `wsl --shutdown` / `wsl --terminate`, never kill `code` processes in WSL, and never click-test
  Dev Control's Stop WSL / Quit VS Code for real** - Claude Code usually runs inside Linux VS Code in
  WSL, so any of these kills the session. Restarting `msrdc.exe` is safe (Linux apps survive).
- **Windows PowerShell 5.1 is the target** (what every Windows 11 machine has): no `&&`, `??`, ternary,
  `-AsHashtable`. `.ps1`/`.xaml` files ASCII-only (5.1 reads BOM-less files as ANSI). Check with
  `[System.Management.Automation.Language.Parser]::ParseFile` and `Select-String -Pattern '[^\x00-\x7F]'`.
- **Native-command quoting in 5.1:** double quotes inside arguments to `wsl.exe` are mangled. Use single
  quotes / no quotes in `sh -c` strings, pass paths as separate arguments, or build a
  `ProcessStartInfo.Arguments` string with MSVC quoting (`\"`) as `wslg-helper.ps1` does. For anything
  non-trivial, write a script file and run it with `wsl -d <distro> -- bash /mnt/c/.../file.sh`.
- **Linux scripts keep LF line endings** (`.gitattributes`); they are POSIX `sh`, not bash.
- **Everything the installer adds, the uninstaller removes** - update both together and the change table
  in `docs/how-it-works.md`. Linux files carry the marker `WSL-Windows-KD-Custom-Setup` so uninstall only
  deletes its own files.
- **wl-paste / wl-copy steal Windows focus** under WSLg (no data-control protocol, so they create a
  transient window). Never call them in a loop or from Linux in the background; the helper calls
  `wl-copy` only on focus-enter into a Linux window.

## Tool registry

### install.ps1 / uninstall.ps1
- Path: repo root; shared helpers in `windows/lib/common.ps1`. Fix log: `docs/fixes.md`.
- Purpose: per-component install/uninstall (Linux side, launchers, WSLg Helper, drag-to-snap, Dev Control).
  Writes `%LOCALAPPDATA%\Programs\WSL-Windows-KD-Custom-Setup\state.json` (distro, components).
- Invocation: `powershell -ExecutionPolicy Bypass -File .\install.ps1 [-Yes] [-Distro X] [-ProjectsRoot /home/u/dir] [-VerifyOnly]`.
- Every run ends with `Test-Setup` (common.ps1): one OK/PENDING/MISSING row per fix; exit code of
  `-VerifyOnly` = number of MISSING. A new fix must get a row there. Step 3 installs `wl-clipboard` itself
  if step 1 was skipped (the helper's paste fix depends on `wl-copy`).
- Test without touching the real machine: parse checks; the Linux part in a temp `HOME`
  (`HOME=$(mktemp -d) sh linux/setup-linux.sh user`).

### linux/setup-linux.sh
- Modes: `packages` (root: Linux VS Code via Microsoft apt repo, wl-clipboard, xclip, sox, pulse utils,
  Noto fonts, xdg-utils), `user` (launchers to `~/.local/bin`, desktop entries, argv.json keys), `uninstall-user`, `check`.

### windows/wslg-helper/wslg-helper.ps1
- Installed to `%LOCALAPPDATA%\Programs\WslgHelper`, scheduled task `WSLg Helper` (logon, conhost --headless,
  `powershell -STA`). Log: `wslg-helper.log` next to it. `-Status` prints both monitor layouts.
- Monitor sync: parses `\\wsl.localhost\<distro>\mnt\wslg\weston.log` incrementally (`rdpMonitor[n]` blocks,
  group starts at index 0), compares with `EnumDisplayMonitors` (per-monitor DPI aware), restarts `msrdc.exe`.
- Clipboard: `GetClipboardSequenceNumber` + clipboard owner PID (msrdc = came from Linux) + foreground PID.
  Focus enters Linux with a pending Windows image -> PNG -> `wl-copy --type image/png`; focus leaves with the
  clipboard unchanged since -> `Clipboard.SetImage` restores it.

### devcontrol/
- See `devcontrol/CLAUDE.md` (Deploy.ps1, Uninstall-DevControl.ps1, tests/Run-SelfTest.ps1).

## WSLg facts (verified on WSL 2.7 / WSLg 1.0.73, Windows 11 26200)
- WSLg system distro: `wsl --system -d <distro>`; Weston modules in `/usr/lib/libweston-9/`.
- `rdprail-shell` env knobs (via `.wslgconfig [system-distro-env]`): `WESTON_RDPRAIL_SHELL_LOCAL_MOVE`,
  `..._ALLOW_ZAP`, `..._ALLOW_ALT_F4_TO_CLOSE_APP`, `..._DEBUG_LEVEL`, ... Values are logged at the top of
  `weston.log` (`RDPRAIL-shell: local-move:0`).
- Clipboard formats bridged: `text/plain;charset=utf-8`, `text/html`, `text/rtf`, `image/bmp`. No PNG.
- `msrdc.exe` exits and is relaunched by WSLGd on every sleep/wake/display change; killing it is the
  supported-by-behaviour way to force a fresh monitor layout.
- `wslg.exe` may exit -1 without running anything; use `conhost.exe --headless wsl.exe -e ...`.
- WSLg regenerates "Visual Studio Code (<distro>)" in the Start Menu from `/usr/share/applications/code.desktop`
  (not from the `~/.local/share/applications` override), without our flags. Documented, not fixed.

## Open items
- WSLg's own "Visual Studio Code (<distro>)" Start Menu entry bypasses `code-linux`.
- WSL idle shutdown under an open Linux VS Code window (Dev Control's keep-alive covers it while it runs).
- Linux home folder visibility in Explorer's navigation pane (not investigated).
