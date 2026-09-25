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
