# Troubleshooting

Start with the helper's status - it shows both monitor layouts side by side:
```powershell
powershell -STA -File "$env:LOCALAPPDATA\Programs\WslgHelper\wslg-helper.ps1" -Status
Get-Content "$env:LOCALAPPDATA\Programs\WslgHelper\wslg-helper.log" -Tail 20
```
WSLg's own log (from Windows): `\\wsl.localhost\<distro>\mnt\wslg\weston.log`.

## Clicks land in the wrong place / windows snap or maximize to the wrong size
1. Run `-Status` above. If `Windows:` and `WSLg:` differ, the monitor layout is stale (see
   [how-it-works](how-it-works.md#1-stale-monitor-layout-after-sleep-clicks-land-in-the-wrong-place-bad-snapping)).
   The helper fixes it within ~15 s; to fix it by hand, end `msrdc.exe` in Task Manager - it comes back
   in about a second and Linux apps keep running.
2. If the layouts match but the pointer is offset everywhere, VS Code was started without
   `--ozone-platform=wayland`. Start it from **VS Code (Linux)**, not from the automatic
   "Visual Studio Code (<distro>)" entry that WSLg adds to the Start Menu (that one runs VS Code
   without the flags).
3. Check the task is running: `Get-ScheduledTask 'WSLg Helper'` should be `Running`.

## Dragging a Linux window to a screen edge does not snap
Win+Arrow works but dragging does not: check `weston.log` for `local-move:` near the top. `local-move:0`
means `.wslgconfig` has not been applied yet - run `wsl --shutdown` (closes all Linux apps) and start
VS Code again. It should then log `local-move:1`.

## Pasting a screenshot into Linux VS Code / the Claude panel does nothing
- After copying, click into the Linux window and wait ~1 s before Ctrl+V (the helper converts on
  focus change). The log shows `clipboard: handed image ... to Linux as PNG`.
- `clipboard: wl-copy failed` in the log: install `wl-clipboard` in the distro
  (`sudo apt install wl-clipboard`), or rerun `install.ps1` step 1.
- In the Claude Code CLI (terminal), image paste needs `wl-clipboard` only.

## A shortcut / right-click does nothing
Run the same command in PowerShell to see errors:
```powershell
wsl.exe -d Ubuntu -e ~/.local/bin/code-linux-open    # replace Ubuntu with your distro
```
- `code-linux: not found` - rerun `install.ps1` (step 1).
- It hangs - `DONT_PROMPT_WSL_INSTALL` is missing; you are running an old `code-linux`.

## The integrated terminal can't find `claude`, `gh`, etc.
`code-linux` loads `~/.profile` when `~/.local/bin` is not on `PATH`. Make sure your tools' paths are
added in `~/.profile` (not only in `~/.bashrc`, which non-interactive launches do not read).

## Links open inside Linux instead of the Windows browser
`echo $BROWSER` in the VS Code terminal should print `.../winbrowser`. For other Linux apps:
`xdg-mime query default x-scheme-handler/https` should print `winbrowser.desktop`.

## Undo everything
```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```
