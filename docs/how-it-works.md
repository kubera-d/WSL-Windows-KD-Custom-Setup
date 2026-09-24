# How it works

This project runs **Linux VS Code** (the real Linux build, installed inside a WSL 2 distro) as a
normal-looking Windows app through **WSLg**, and patches the rough edges WSLg has on a typical
multi-monitor Windows 11 desktop.

## Why Linux VS Code instead of Windows VS Code + Remote-WSL?

Windows VS Code connected to WSL (`code --remote wsl+Ubuntu`) works well for most things, but in a
remote window some extensions disable features that need local hardware. The motivating case: the
Claude Code extension's **voice dictation** is only offered when the window is *not* remote. Linux
VS Code running inside WSL is "local" to Linux, gets the microphone through WSLg's PulseAudio
server, and sees the Linux filesystem, tools and Docker natively.

Windows VS Code stays installed and gets its own Start Menu entry, **VS Code (Windows)**, as the
rollback: if WSL is broken, you still have an editor to fix it with.

## The pieces

```
Windows                                              Linux (WSL 2 distro)
-------                                              --------------------
Start Menu "VS Code (Linux)"  --+                    ~/.local/bin/code-linux-open  (Windows path -> Linux path)
Desktop "VS Code (Linux)"     --+-> conhost --headless        |
Explorer right-click          --+   wsl.exe -e ... ---------->+
Dev Control "VS Code" button  ----> wsl.exe bash -lc ------> ~/.local/bin/code-linux    (flags, env)
Terminal: `code`              -------------------------------> ~/.local/bin/code -> code-linux
                                                                      |
                                                              /usr/share/code/bin/code --ozone-platform=wayland --disable-gpu
                                                                      |
WSLg (msrdc.exe on Windows  <== RDP ==>  Weston compositor in the WSLg system distro)
      |
WSLg Helper (scheduled task): monitor resync + clipboard images
%USERPROFILE%\.wslgconfig: drag-to-snap
```

### `code-linux` - one place for the launch flags

| Setting | Why |
|---|---|
| `--ozone-platform=wayland` | Under X11 (Xwayland) the window glitches and the **mouse pointer is offset** from where you click, because of Windows display scaling. Wayland goes straight to WSLg's compositor. |
| `--disable-gpu` (+ `disable-hardware-acceleration` in `~/.vscode/argv.json`) | WSLg's GPU path causes redraw glitches. |
| `DONT_PROMPT_WSL_INSTALL=1` | VS Code's `bin/code` otherwise asks "install VS Code in Windows instead? [y/N]" on stdin - every launcher without a terminal would hang silently. |
| sources `~/.profile` when `~/.local/bin` is not on `PATH` | Launches from Windows (`wsl.exe -e`) get a bare `PATH`, and the `code` CLI tells VS Code not to resolve the login shell itself, so the integrated terminal would not find user-installed tools. |
| `BROWSER=~/.local/bin/winbrowser` | Links (sign-in pages etc.) open in the Windows default browser. |
| `password-store: basic` in `argv.json` | There is no OS keyring in WSL; without this VS Code complains about secret storage. |

### Windows launchers
Shortcuts and the right-click entry run `conhost.exe --headless wsl.exe -d <distro> -e ~/.local/bin/code-linux-open`.
The headless console means no console window flashes up. `wslg.exe` is not used because on some
machines it exits with -1 without running anything. `code-linux-open` converts every form of path
Explorer can pass (`C:\...`, `\\wsl.localhost\<distro>\...`, `\\wsl$\...`, collapsed backslashes)
because `wsl.exe --cd` rejects UNC paths.

## WSLg problems and their fixes

### 1. Stale monitor layout after sleep (clicks land in the wrong place, bad snapping)
WSLg shows Linux windows through a hidden RDP connection (`msrdc.exe`). When the PC sleeps or the
screens turn off, that connection drops and reconnects about a second later - often while only one
screen (e.g. the laptop panel) is awake. WSLg's compositor receives that one-monitor layout and
never learns that the other monitors came back. Every pointer position and snap/maximize size is
then computed against the wrong desktop.

You can see it in `\\wsl.localhost\<distro>\mnt\wslg\weston.log`: the last `rdpMonitor[...]` block
lists fewer or differently sized monitors than Windows has.

**Fix - WSLg Helper, part 1:** every 5 s (only while WSLg is running) it compares the Windows
monitor layout with the last layout in `weston.log`. If they differ once the Windows layout has
been stable for 10 s, it restarts `msrdc.exe`. WSLg relaunches it within about a second with the
correct layout; Linux apps keep running (their windows blink). At most one restart per 2 minutes,
and it gives up on a mismatch after 3 tries until the layout changes again.

### 2. Dragging a Linux window to a screen edge does not snap
Win+Arrow works, dragging does not. By default WSLg's shell (`rdprail-shell`) performs title-bar
drags itself and just streams positions to Windows, so Windows never sees a user drag and never
shows Snap. The shell has an option to hand drags to Windows' own move loop ("local move"):
`WESTON_RDPRAIL_SHELL_LOCAL_MOVE`. Its current value is logged at WSLg start as `local-move:0/1`.

**Fix:** `%USERPROFILE%\.wslgconfig`
```ini
[system-distro-env]
WESTON_RDPRAIL_SHELL_LOCAL_MOVE=true
```
Takes effect after `wsl --shutdown`.

### 3. Screenshots cannot be pasted into Linux apps
WSLg's clipboard bridge maps Windows images to Linux **only as `image/bmp`** (its RDP backend knows
`image/bmp`, `text/plain`, `text/html`, `text/rtf`). Chromium/Electron apps - Linux VS Code and its
webviews (e.g. the Claude Code panel), browsers - only paste `image/png`, so pasting a Snipping
Tool capture does nothing. (The Claude Code CLI in a terminal reads `image/bmp` via `wl-paste`, so
it only needs `wl-clipboard` installed.)

A Linux-side converter is not viable: WSLg's compositor lacks the wlroots data-control protocol, so
`wl-paste --watch` does not work, and each plain `wl-paste`/`wl-copy` call briefly creates a window
that **steals Windows focus**.

**Fix - WSLg Helper, part 2** (all on the Windows side, which can watch focus and the clipboard for
free):
- When focus moves **into** a Linux window (foreground window owned by `msrdc.exe`) and the Windows
  clipboard holds an image copied on Windows, the helper saves it as PNG and runs
  `wl-copy --type image/png` in the distro. Takes about 0.2-0.5 s.
- Linux now owns the clipboard and WSLg cannot send PNG back, so Windows apps would see no image.
  When focus moves back **out** and nothing new was copied meanwhile, the helper puts the original
  image back on the Windows clipboard.
- Images copied inside Linux apps are left alone.

## Dev Control
An optional Windows app (PowerShell + WPF) to start/stop WSL, switch `.wslconfig` resource modes,
run Docker Compose projects and open them in Linux VS Code. See [`devcontrol/README.md`](../devcontrol/README.md).

## What is changed on the machine

| Where | What | Removed by uninstall.ps1 |
|---|---|---|
| Linux (root) | Linux VS Code via Microsoft apt repo (if missing); `wl-clipboard xclip sox libsox-fmt-pulse pulseaudio-utils fonts-noto-color-emoji fonts-noto-core xdg-utils` | no (listed) |
| Linux `~/.local/bin` | `code-linux`, `code-linux-open`, `winbrowser`, `code` symlink | yes |
| Linux `~/.local/share/applications` | `code.desktop` override, `winbrowser.desktop`; xdg default for http/https/mailto | yes |
| Linux `~/.vscode/argv.json` | `disable-hardware-acceleration`, `password-store` (only if missing) | no |
| Windows Start Menu / Desktop | `VS Code (Linux)`, `VS Code (Windows)`, `Dev Control` | yes |
| `HKCU\Software\Classes\Directory[\Background]\shell\VSCodeWSL` | right-click "Open in VS Code (Linux)" | yes |
| Task Scheduler | `WSLg Helper` (at logon, your user, not elevated) | yes |
| `%LOCALAPPDATA%\Programs\WslgHelper` | helper script, config, log | yes |
| `%USERPROFILE%\.wslgconfig` | `WESTON_RDPRAIL_SHELL_LOCAL_MOVE=true` | yes |
| `%LOCALAPPDATA%\Programs\DevControl` | Dev Control app | yes (settings backed up) |
| `Cert:\CurrentUser\{My,Root,TrustedPublisher}` | `CN=KD Dev Tools` code-signing cert (only if you chose signing) | optional |
