# Fix log

Problems hit while building this setup, and what fixed them. Newest last. (Dev Control's own
fixes are in [`devcontrol/docs/fixes.md`](../devcontrol/docs/fixes.md).)

### FIX-001 - Mouse pointer offset and window glitches in Linux VS Code
- **Symptom:** clicks land away from the pointer; window redraw glitches.
- **Cause:** VS Code under Xwayland with Windows display scaling; WSLg GPU path.
- **Fix:** launch with `--ozone-platform=wayland --disable-gpu` (in `code-linux`), `disable-hardware-acceleration` in `argv.json`.

### FIX-002 - Launchers without a terminal hang silently
- **Symptom:** shortcuts / right-click / Dev Control start nothing.
- **Cause:** VS Code's `bin/code` inside WSL prompts "install VS Code in Windows instead? [y/N]" on stdin.
- **Fix:** `export DONT_PROMPT_WSL_INSTALL=1` in `code-linux`.

### FIX-003 - Integrated terminal can't find user tools when started from Windows
- **Cause:** `wsl.exe -e` gives a bare `PATH`; the `code` CLI disables login-shell env resolution.
- **Fix:** `code-linux` sources `~/.profile` when `~/.local/bin` is missing from `PATH`.

### FIX-004 - `wslg.exe` shortcuts and `wsl.exe --cd` with UNC paths fail
- **Symptom:** `wslg.exe` exits -1 and runs nothing; `wsl.exe --cd \\wsl.localhost\...` -> `E_INVALIDARG`.
- **Fix:** launch via `conhost.exe --headless wsl.exe -e code-linux-open`, which converts the path itself.

### FIX-005 - `wslview` unavailable
- **Cause:** `wslu` is not packaged for newer Ubuntu releases.
- **Fix:** `winbrowser` (rundll32 `url.dll,FileProtocolHandler`, web/mail URLs only) as `$BROWSER` and xdg default.

### FIX-006 - Clicks misplaced / bad snapping after sleep or screen-off
- **Cause:** `msrdc.exe` reconnects while only one monitor is awake; WSLg keeps that layout.
- **Fix:** WSLg Helper restarts `msrdc.exe` when `weston.log`'s last layout differs from Windows'.

### FIX-007 - Drag-to-edge snap does nothing (Win+Arrow works)
- **Cause:** WSLg `rdprail-shell` `local-move:0` (default) - drags never reach Windows' move loop.
- **Fix:** `.wslgconfig` `[system-distro-env] WESTON_RDPRAIL_SHELL_LOCAL_MOVE=true`, then `wsl --shutdown`.

### FIX-008 - Screenshots don't paste into Linux VS Code / Claude panel
- **Cause:** WSLg bridges images only as `image/bmp`; Chromium/Electron paste only `image/png`. Linux-side
  watchers are impossible (no data-control protocol) and `wl-paste`/`wl-copy` steal Windows focus.
- **Tried:** systemd user service with `wl-paste --watch` - fails ("Watch mode requires a compositor that
  supports the wlroots data-control protocol"); polling - steals focus.
- **Fix:** WSLg Helper converts to PNG and `wl-copy`s it when focus enters a Linux window, and restores the
  bitmap for Windows apps when focus leaves.

### FIX-009 - Clicks ignored / pointer stays an arrow over some buttons after screens change
- **Symptom:** after sleep or unplugging/turning off monitors, some buttons in Linux VS Code (e.g. the
  Claude panel's choice buttons) don't react and the pointer doesn't turn into a hand over them; others work.
- **Cause:** WSLg got the change as a LIVE `DisplayLayoutChange` inside the existing RDP connection. The
  layout then matched Windows, so FIX-006's mismatch check did nothing, but the Linux windows' input
  state was left stale.
- **Fix:** the WSLg Helper also restarts `msrdc.exe` once after a live `DisplayLayoutChange` (once the Windows
  layout has been stable for 10 s; a fresh connection clears the flag, so no loop). Manual fix:
  `Stop-Process -Name msrdc -Force` (Linux apps keep running).

### FIX-010 - Stop WSL "doesn't work": WSL boots straight back up, vmmemWSL can't be ended
- **Symptom:** WSL makes Windows slow; Dev Control's Stop WSL fails with "WSL still reports running 30s
  after --shutdown"; `vmmemWSL` keeps using memory and Task Manager says "Access denied". Only a hard
  reset helped.
- **Cause:** the shutdown itself worked (WSL reported stopped after 3 s). Another 3 s later, the WSLg Helper's
  monitor sync opened `\\wsl.localhost\<distro>\mnt\wslg\weston.log`, and opening anything under
  `\\wsl.localhost` boots the distro. Its only guard was "msrdc.exe is running", but msrdc outlives a
  shutdown by a few seconds (and its PID list was cached for 2 s). The new boot's 0x0 placeholder layout
  also looked like a mismatch, so the helper killed msrdc. Task Manager cannot end `vmmemWSL` at all:
  the hypervisor owns that process.
- **Fix:** the helper touches Linux (weston.log, `wsl.exe wl-copy`) only when `Test-DistroUp` holds: `vmmemWSL`
  exists (checked fresh), Dev Control's stop marker `%LOCALAPPDATA%\DevControl\wsl-stopping` is not fresh
  (< 2 min), and `wsl --list --running` lists the distro (cached 15 s). 0x0 layouts are ignored. Dev Control's
  Stop WSL writes the marker, runs `wsl --shutdown`, then `wsl --shutdown --force`, and each step must leave
  WSL down (no distro running AND no `vmmemWSL`) for 8 s. If WSL comes back, `app.log` lists the Windows-side
  WSL clients and their parents. If both steps fail, it offers a force stop (UAC): `hcsdiag kill` on the WSL VM,
  then ending `wslservice.exe` if the VM is still there.
- **Manual equivalent (admin PowerShell):** `wsl --shutdown --force`; if that hangs:
  `hcsdiag list` (the line ending in `WSL`) > `hcsdiag kill <id>`, or `Stop-Process -Name wslservice -Force`.
  A normal Start > Restart also works; there's no need to hold the power button.
- **Also:** the helper now lives only as long as WSL. Its task has no logon trigger; Dev Control's
  `Start-DcWslBoot` starts it, and it exits when `vmmemWSL` is gone or the stop marker is fresh. Starting
  WSL any other way does not start the helper (`Start-ScheduledTask 'WSLg Helper'` does).

### FIX-011 - The Linux log of a bad session is gone after a restart
- **Symptom:** `journalctl -b -1` / `--list-boots` shows only the current boot although `/var/log/journal`
  exists (persistent) and holds ~370 MB, so after a hang there's nothing left to look at.
- **Cause:** WSL keeps the Linux clock in sync with Windows itself. Ubuntu's `chrony` steps it back
  ("System clock interference detected (another NTP client?)"), and journald starts a new file on every
  backwards jump ("Time jumped backwards, rotating."): 79 rotations in 5.5 h. Its default 100-file limit
  then deletes earlier boots within hours.
- **Fix:** `setup-linux.sh journal` (root, install step 1) disables `chrony` (records that in
  `/var/lib/wsl-windows-kd-custom-setup/chrony-disabled`) and adds the journald drop-in
  `50-wsl-windows-kd-custom-setup.conf` (`Storage=persistent`, `SystemMaxUse=1G`, `SystemMaxFiles=1000`).
  `uninstall-root` removes the drop-in and re-enables chrony. Previous session: `sudo journalctl -b -1`
  (`-k` for kernel/OOM messages).

### FIX-012 - Linux windows vanish after undocking (not on screen, not in the taskbar)
- **Symptom:** after unplugging the dock, Linux VS Code windows that were on the external screens are
  gone: no window, no taskbar button. VS Code still has them open (`storage.json` `openedWindows`).
- **Cause (from weston-mirror source + weston.log):** at undock Windows minimizes or leaves the Linux
  windows of the disconnected screens; 10 s later the WSLg Helper restarted `msrdc` (FIX-009). On
  reconnect `rdp_rail_sync_window_status` re-creates a RAIL window only for views in the compositor's
  view list; rdprail-shell keeps a minimized view in `minimized_layer`, which is not in that list, and
  only a RAIL restore/activate for that window id (`set_unminimized`) brings it back - an id the new
  `msrdc` never had. weston.log: VS Code windows `0x1 0x2 0x4` before, only `0x2` re-sent after. Nothing
  a Linux client can request (open a file, fullscreen, maximize) re-maps it, and adding screens back does
  not change its layer.
- **Fix (prevention):** the helper never restarts `msrdc` while a Linux window is minimized
  (`IsIconic` `RAIL_WINDOW`), or while one is off every screen: in the first minute after a screen change
  it moves those onto the primary screen (`SetWindowPos`; local-move on, FIX-007, so WSLg takes the
  position - `Move order` in weston.log), waits a pass, and skips the restart if they will not move.
  `-Status` lists minimized / off-screen Linux windows, `-Rescue` moves off-screen ones by hand.
- **Recovery once lost:** none found that keeps the window: the VS Code window has to be closed and its
  folder reopened (editors come back via hot exit; terminals in it end).

### FIX-013 - Windows files not visible in Linux VS Code's Open dialog
- **Symptom:** File > Open File / Open Folder in Linux VS Code shows only the Linux home; the Windows drive
  appears nowhere (typing `/mnt/c` works, and `/mnt/c` itself is mounted and readable).
- **Cause:** Electron uses the GTK file chooser (no xdg-desktop-portal in the distro); its sidebar lists
  only `$HOME`, XDG folders and `~/.config/gtk-3.0/bookmarks`, which was empty. The 9p mount of `C:` is
  not offered by GVfs.
- **Fix:** `setup-linux.sh user` adds two bookmarks, `Windows (C:)` (`/mnt/c`) and `Windows home` (the
  Windows profile, from `%USERPROFILE%` via interop + `wslpath`); idempotent; `uninstall-user` removes
  only those two lines (GTK bookmarks have no comment syntax, so no marker). Takes effect on the next
  dialog, no restart. `Test-Setup` row "Windows drive in Linux file dialogs".

### FIX-014 - WSL freezes solid when memory runs out
- **Symptom:** every Linux window stops responding; `wsl.exe` cannot even start a command
  (`Wsl/Service/0x8007274c`, connection timed out); weston.log stops being written.
- **Cause:** Linux used all RAM (10 GB `.wslconfig` limit) and all 8 GB swap - several VS Code windows,
  ~8 Claude Code sessions, a handful of dev servers, then a 1.7 GB test script on top. `/proc/pressure/memory`
  full avg10 90%, MemAvailable 160 MB, load 128, all 6 vCPUs ~93% busy reclaiming. The kernel OOM killer
  did not fire: reclaim keeps making a little progress, so the VM thrashes instead of killing anything.
  (Diagnosed from Windows by reading `\wsl.localhost\<distro>\proc\...` - the 9p file server still answers
  when process creation no longer does.)
- **Fix:** `setup-linux.sh earlyoom` (root, install step 1) installs `earlyoom` with a marked systemd drop-in:
  `-m 5 -s 50` (acts when available RAM < 5% and free swap < 50%), `--avoid` VS Code, Claude Code, systemd and
  the WSLg/session plumbing, `--prefer` python / node / workerd / java (test scripts and dev servers).
  It ends one process (SIGTERM, then SIGKILL) and logs it: `journalctl -u earlyoom`. `uninstall-root` removes
  the drop-in and disables the service if install enabled it.
- **Recovery from a freeze that already happened:** nothing inside Linux can run; restart WSL
  (Dev Control Stop WSL, or `wsl --shutdown` from Windows).

### FIX-015 - Screenshot paste into Linux VS Code works, then stops again
- **Symptom:** Win+Shift+S then Ctrl+V in Linux VS Code / the Claude panel does nothing - sometimes. The
  helper log shows a hand-off undone within 1-2 s: `handed image ... to Linux as PNG` immediately
  followed by `restored image for Windows apps` (pattern present since FIX-008 went in).
- **Cause:** `wl-copy` opens its own short-lived window to take the Wayland clipboard; under WSLg that
  steals Windows focus and Windows often gives it back to the previous Windows app, not to VS Code. The
  helper read that as "focus left Linux" and put the bitmap back on the Windows clipboard (FIX-008's
  restore), which WSLg forwarded to Linux as `image/bmp`, replacing the PNG. Chromium/Electron cannot
  paste BMP, so the next Ctrl+V in Linux did nothing.
- **Fix:** the helper ignores focus changes for 3 s after a hand-off (`$GraceMs`) and only treats Linux
  as left once a Windows app has kept focus for 1.5 s (`$LeaveMs`). The restore line now names the app
  focus went to, so a recurrence is visible in `wslg-helper.log`.

### FIX-016 - All Linux VS Code windows close at once under load (sessions "crash")
- **Symptom:** every Linux VS Code window disappears together; Claude Code sessions in them end. WSL itself
  keeps running (wsl.exe answers, memory free); VS Code's main.log shows an orderly shutdown (storage closed,
  extension hosts exit code 0) - nothing quit it on purpose.
- **Cause:** weston.log, one second earlier: `libwayland: error in client communication (pid <VS Code main>)`.
  Linux was swapping hard (6 of 8 GB swap used, load 24: Playwright browsers on top of three Astro dev servers).
  VS Code's main process stalled on swap-in, stopped reading its Wayland events, Weston's fixed per-client
  buffer overflowed and Weston dropped the client; an Electron app that loses its display quits. Weston's
  buffer size is part of the WSLg system image and cannot be changed, and earlyoom does not act while RAM is
  free, so the fix is to keep the interactive app out of swap.
- **Fix:** `setup-linux.sh earlyoom` also writes `/etc/sysctl.d/60-wsl-windows-kd-custom-setup.conf` with
  `vm.swappiness = 10` (default 60): idle memory of interactive apps stays in RAM, swap is used only under real
  pressure. Applied live (`sysctl -p`). `uninstall-root` removes it and sets 60 again. `Test-Setup` row
  "VS Code kept in RAM (no swap stalls)".
- **Recovery:** reopen the folders (VS Code restores editors and auto-resumes the Claude tabs that were open).

### FIX-017 - Linux windows stop opening after the screen was off, or WSL stops under open windows
- **Symptoms:** (a) after the screen was off / locked for a while, the Linux VS Code windows are still in the
  taskbar but clicking them shows nothing; (b) later, every Linux window disappears and WSL is stopped
  ("WSL stopped - exiting" in the helper log) although nobody stopped it.
- **Cause (a):** weston.log `rdp_rail_idle_handler` ... `rdp_rail_wake_handler` (31 min idle): after the wake
  the msrdc windows were stale. A msrdc restart fixed it; the helper only restarted on layout changes.
- **Cause (b):** the previous Linux boot ends abruptly (journal: no shutdown sequence, no OOM; the last lines
  are `WSL (...Relay) ERROR: UtilAcceptVsock: Waiting for abnormally long accept`), i.e. the VM was ended from
  the Windows side. Afterwards no Dev Control keep-alive session (`wsl.exe ... exec sleep infinity`) existed,
  and Linux GUI apps do not count as WSL clients - so WSL can idle out under open windows once the keep-alive is
  gone. (A short-lived wsl.exe crashed at 01:14 with 0xc00000fd in RPCRT4; it was not the keep-alive.)
- **Fix:** the helper (a) restarts msrdc once, 10 s after a wake that followed >= 20 min of WSLg idle (5 min was too eager: a short break made the windows blink) (same
  safety guard as FIX-012: never with a minimized or off-screen Linux window); (b) checks every 30 s that a
  keep-alive session exists while the distro is up and starts one if not (honours Dev Control's
  `keepAlive` setting; never boots WSL). `-Status` shows the keep-alive count.
- **Diagnosing note:** reading `\wsl.localhost\...` while WSL is stopped boots it (FIX-010) - check
  `wsl --list --running` or vmmemWSL first.

### FIX-018 - Copy in Linux VS Code, paste in Outlook does nothing (Notepad works)
- **Symptom:** text copied in Linux VS Code (editor or Claude panel) pastes into Notepad but not into Outlook.
- **Cause:** VS Code / Chromium put plain text and an HTML fragment on the clipboard. WSLg advertises
  "HTML Format" to Windows, but its Linux-to-Windows conversion (`clipboard_process_html`, send direction)
  requires an `<html>` tag and `<body>`, which Chromium's fragments (`<meta charset='utf-8'><div>...`) lack.
  Outlook asks for HTML first, the request fails (weston.log: four `clipboard_process_html FAILED ... send`
  per paste) and Outlook does not fall back to text.
- **Fix:** when a new clipboard owned by msrdc (= copied in Linux) lists "HTML Format" that cannot be fetched,
  the WSLg Helper puts the plain text back on the Windows clipboard itself (`Repair-LinuxHtmlCopy`). Windows
  apps then paste the text; formatting (syntax colours) is lost, but WSLg could not deliver it anyway.

### FIX-019 - Helper fixes silently off when WSL was started without Dev Control
- **Symptom:** clipboard / window fixes (FIX-012, 015, 017, 018) sometimes "stop working"; `wslg-helper.log`
  shows no `started` line since WSL last booted.
- **Cause:** the `WSLg Helper` task had no trigger - only Dev Control's Start WSL started it. WSL started any
  other way (opening a Linux app, a `wsl` command, Explorer touching `\wsl.localhost`) ran without the helper.
- **Fix:** the task triggers at logon and every 2 minutes, indefinitely (`Get-HelperTriggers` in common.ps1).
  A run while the helper is up is skipped (`MultipleInstances IgnoreNew` + its mutex); a run while WSL is down
  exits at once without touching WSL and logs that only once in a row. So the helper is up within 2 minutes
  of WSL starting, however it started.

### FIX-020 - Linux VS Code "crashes": WSLg's display server (Weston) crashed
- **Symptom:** all Linux VS Code windows vanish; VS Code is gone. Kernel log:
  `weston[...]: segfault at ... in libc.so.6`; `/mnt/wslg/stderr.log`: `WSLGd: ... terminated with signal 11,
  /usr/bin/weston ...`; weston.log starts over (`Command line: /usr/bin/weston ...`). Seen right after a long
  WSLg idle (screen off). A Microsoft WSLg bug - not fixable here.
- **Also:** the FIX-017 wake rule then restarted msrdc during the recovery (idle start from the old Weston, wake
  from the new one), so the windows blinked away a second time.
- **Fix:** the helper (a) forgets idle/wake state when Weston restarts, so the wake rule cannot fire on a fresh
  display server; (b) when Weston restarts and Linux VS Code windows were on screen within the 3 minutes before,
  waits 15 s and - if no VS Code process is left - runs `code-linux` with no folder, which restores every window
  of the last session (tabs, Claude panels). Log: "WSLg display server crashed and restarted - reopened Linux
  VS Code". Conversations that were mid-reply need "continue".
