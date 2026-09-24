# WSL Windows KD Custom Setup

Use **Linux VS Code** (running inside WSL 2) as your everyday editor on Windows 11 - launched from
the Start Menu, Explorer's right-click menu or a desktop shortcut like any Windows app - with fixes
for the WSLg problems that otherwise make it frustrating on a multi-monitor desktop:

- **Offset mouse pointer / glitchy window**: launched with the right flags.
- **Clicks land in the wrong place after sleep or screen-off**: WSLg keeps a stale monitor layout. A small background helper notices and refreshes it.
- **Dragging a window to a screen edge doesn't snap**: turns on WSLg's option that hands drags to Windows.
- **Screenshots won't paste into Linux apps** (Snipping Tool -> VS Code / Claude Code panel): the helper converts the image into a format Linux apps accept, and restores it for Windows apps.
- **Links open in the Windows browser**, the integrated terminal gets your full `PATH`, and no hidden prompts hang the launchers.

It also includes **Dev Control**, an optional Windows app to start/stop WSL, switch memory/CPU
"modes", run Docker Compose projects and open them in Linux VS Code.

Windows VS Code stays installed and gets its own Start Menu entry, **VS Code (Windows)**.

## Why?
Windows VS Code + Remote-WSL is great, but some features only work when VS Code runs locally. The
motivating one: the Claude Code extension's voice dictation is not offered in remote windows. Linux
VS Code under WSLg is local to Linux, gets the microphone through WSLg, and sees Linux tools and
Docker natively. Details: [docs/how-it-works.md](docs/how-it-works.md).

## Requirements
- Windows 11 with WSL 2 and WSLg (`wsl --update` for the latest).
- A WSL distro with a normal user. Tested with Ubuntu (`wsl --install -d Ubuntu`). The Linux setup
  uses `apt`, so Debian/Ubuntu-based distros are supported.
- Windows VS Code is optional (only for the "VS Code (Windows)" shortcut and its icon).

## Install
```powershell
git clone https://github.com/kubera-d/WSL-Windows-KD-Custom-Setup.git
cd WSL-Windows-KD-Custom-Setup
powershell -ExecutionPolicy Bypass -File .\install.ps1
```
The installer asks before each part (all per-user, no admin; the Linux packages step uses `wsl -u root`):

| Step | What you get |
|---|---|
| 1. Linux side | Linux VS Code (if missing), clipboard/voice/font packages, `code-linux` launchers in `~/.local/bin` |
| 2. Launchers | Start Menu **VS Code (Linux)** and **VS Code (Windows)**, right-click **Open in VS Code (Linux)**, optional desktop shortcut |
| 3. WSLg Helper | background task: monitor-layout resync after sleep + screenshot paste |
| 4. Drag-to-snap | `%USERPROFILE%\.wslgconfig` setting (applies after `wsl --shutdown`) |
| 5. Dev Control | optional app; can sign its launcher with a local certificate so SmartScreen stays quiet |

Linux packages installed in step 1: `code` (Linux VS Code, from Microsoft's apt repo, if missing),
`wl-clipboard`, `xclip`, `sox`, `libsox-fmt-pulse`, `pulseaudio-utils`, `fonts-noto-color-emoji`,
`fonts-noto-core`, `xdg-utils`.

At the end the installer checks that every fix is actually in effect and prints OK / PENDING /
MISSING for each (drag-to-snap stays PENDING until WSL restarts). Run the check alone any time:
`.\install.ps1 -VerifyOnly`.

Non-interactive: `.\install.ps1 -Yes -Distro Ubuntu`. Re-running is safe (it updates in place).

## Use
- **Start Menu -> VS Code (Linux)**: reopens your last workspace.
- **Right-click a folder** (Windows 11: *Show more options*) -> **Open in VS Code (Linux)**. Works for
  Windows folders (`C:\...`, opened via `/mnt/c`) and Linux folders (`\\wsl.localhost\...`).
- In a WSL terminal: `code .` (the `code` command now points at `code-linux`).
- **VS Code (Windows)**: the regular Windows VS Code.

Note: WSLg also adds its own "Visual Studio Code (Ubuntu)" Start Menu entry. It starts VS Code
without the fixes - use **VS Code (Linux)** instead.

## Uninstall
```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```
Removes everything the installer added (asks per part). Windows VS Code, Linux VS Code and apt
packages stay installed. Full list of changes: [docs/how-it-works.md](docs/how-it-works.md#what-is-changed-on-the-machine).

## Troubleshooting
See [docs/troubleshooting.md](docs/troubleshooting.md). Quick check:
```powershell
powershell -STA -File "$env:LOCALAPPDATA\Programs\WslgHelper\wslg-helper.ps1" -Status
```

## Repository layout
```
install.ps1 / uninstall.ps1    entry points (Windows PowerShell 5.1)
windows/lib/common.ps1         shared installer helpers
windows/wslg-helper/           background helper (monitor resync, clipboard images)
linux/setup-linux.sh           Linux side: packages, launchers, desktop entries, argv.json
linux/bin/                     code-linux, code-linux-open, winbrowser
devcontrol/                    Dev Control app (see its README)
docs/                          how it works, troubleshooting, fix log
```

## License
MIT - see [LICENSE](LICENSE).
