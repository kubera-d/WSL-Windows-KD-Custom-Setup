# Dev Control

A small Windows desktop app for running a WSL2 dev environment from the Windows side:
WSL status and memory, `.wslconfig` "modes", start/stop WSL, Docker Compose projects,
background tools, and opening/quitting VS Code in WSL.

It is Windows PowerShell 5.1 + WPF with a tiny C# launcher compiled by the .NET Framework
`csc.exe` that ships with Windows, so there is nothing to install. It runs on the Windows side,
so it keeps working after `wsl --shutdown`, and it never wakes WSL up by accident.

## Requirements
- Windows 10/11 with WSL2 and a distro (systemd recommended).
- Docker Engine **inside** the distro (`docker compose` v2). Docker Desktop is not needed.
- For the default Linux VS Code flavor: `~/.local/bin/code-linux` inside WSL (a wrapper that
  starts Linux VS Code under WSLg with `--ozone-platform=wayland --disable-gpu` and exports
  `DONT_PROMPT_WSL_INSTALL=1`). This repo's Linux setup installs it; Dev Control does not.
  Or set `"codeFlavor": "windows"` to use Windows VS Code with `--remote wsl+<distro>`.

## Features
- **Status**: WSL running/stopped, VmmemWSL memory, current mode (the mode file whose content
  matches `.wslconfig`), and the live CPU/RAM the VM actually has.
- **Start WSL** in a mode: copies `modes\<mode>.wslconfig` to `%USERPROFILE%\.wslconfig`, then boots.
  If WSL is running in another mode it asks before restarting. With no mode picked it just boots on
  the current `.wslconfig`. A `.wslconfig` that matches no mode is backed up before it is replaced.
- **Stop WSL**: asks, then runs `wsl --shutdown` (frees the VM's memory and CPU).
- **VS Code** card: **Open (no folder)** starts an empty window (booting WSL first if needed);
  **Quit VS Code** closes every VS Code window inside WSL (SIGTERM, SIGKILL after 20 s).
- **Projects**: every folder under `projectsRoot` (a Linux path) is listed and grouped;
  `projects.json` only adds metadata. Each card shows its compose containers **and** background
  tools nested underneath, with CPU/RAM and a Stop button.
  - A folder with no `projects.json` entry appears in a **New** group at the top, so a project you
    just created is noticed on the next refresh (30 s).
  - **Run**: start WSL in the project's `mode` (asks: restart in that mode / run in the current mode /
    cancel) > `docker compose up -d` (optionally only some `services`) > run its `tools` > open VS Code.
  - **Stop**: stop background tools and tool `stop` commands > `docker compose down`.
    **Restart**: compose restart + restart background tools.
  - **Open** (the project's `url`), **VS Code** (starts WSL first if needed).
  - **Pinned** projects get big Run/Stop buttons on the left and in the tray menu.
- **Stop all containers**, plus an "Other containers" group for containers of no listed project.
- **Tray icon**: Open, Run project (pinned), Start WSL (per mode), Stop WSL, Open VS Code, Quit
  VS Code in WSL, Exit. Minimizing hides to the tray.

### Arranging projects (saved, restored every time)
- **Drag** a card onto another card to reorder (top/bottom half = before/after), or onto a
  **group header** to move it into that group.
- Card **...** menu (or right-click): Move up / down, Move to group (or **New group...**),
  Remove from group, Pin/Unpin, Hide/Unhide. Group header menu: Rename, Move up / down, Ungroup.
- **Show hidden** reveals hidden projects (dimmed) so they can be unhidden.
- Changes are written to `projects.json` (`order`, `group`, `groups`, `pinned`, `hidden`). The file
  is re-read before every change, so edits made in a text editor are kept; the previous version is
  saved as `%LOCALAPPDATA%\DevControl\projects.json.bak`.
- Expanded groups and the Show-hidden toggle are per-user view state in
  `%LOCALAPPDATA%\DevControl\ui-state.json`.

## Install
From the repo's top-level installer (which calls Deploy.ps1), or directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\devcontrol\Deploy.ps1 -ProjectsRoot /home/<you>/projects
```

| Parameter | Meaning |
|---|---|
| `-Destination <dir>` | Install folder. Default `%LOCALAPPDATA%\Programs\DevControl`. |
| `-Distro <name>` | WSL distro. Default: your default WSL distro (read from the registry), else `Ubuntu`. |
| `-ProjectsRoot <linux path>` | Folder whose subfolders are your projects, e.g. `/home/alice/projects`. |
| `-Build` | Rebuild icon, `DevControl.exe` (automatic when the exe is missing). |
| `-Sign` | Create/reuse the code-signing certificate, trust it for your user, sign the exe (see below). |
| `-NoDesktopShortcut` | Only create the Start Menu shortcut. |

What it does:
1. Refuses to continue if any `.ps1` / `.xaml` file contains non-ASCII characters.
2. Copies `src\*` to the install folder (your `settings.json` / `projects.json` are never overwritten).
3. Creates `settings.json` once from `settings.default.json`, filling in `distro`, `projectsRoot` and
   `modesDir`. On later runs it only fills `distro` / `projectsRoot` if they are still empty and you
   passed `-Distro` / `-ProjectsRoot`.
4. Creates `projects.json` once from `projects.example.json` (edit it to your own folder names).
5. Copies `modes\*.wslconfig` into `<install>\modes` - only files that are not there yet.
6. Builds the launcher when needed, signs it with `-Sign`, creates the **Dev Control** shortcut in the
   Start Menu (and on the Desktop unless `-NoDesktopShortcut`).

Re-run it after pulling changes. If Dev Control is running it keeps running the old version: exit
it from the tray and start it again. Deploy.ps1 never starts or stops WSL.

## Settings (`<install>\settings.json`)
Restart the app after editing.

| Key | Default | Meaning |
|---|---|---|
| `distro` | `""` = default WSL distro, else `Ubuntu` | Distro to manage. Read from the registry, never from `wsl.exe`. |
| `projectsRoot` | `""` (Deploy.ps1 fills it) | Linux folder whose subfolders are projects. Empty = the app shows "set projectsRoot in settings.json". |
| `modesDir` | `modes` | Folder of `<mode>.wslconfig` files. `%VARS%` are expanded; relative paths are relative to the app folder. |
| `wslConfigPath` | `%USERPROFILE%\.wslconfig` | The file a mode is copied to. |
| `codeFlavor` | `linux` | `linux`: Linux VS Code under WSLg via `~/.local/bin/code-linux`. `windows`: Windows VS Code `--remote wsl+<distro>`. |
| `codePath` | `""` | Path to Windows `code.cmd` (windows flavor), when it is not on PATH. |
| `trayIcon` / `minimizeToTray` / `closeToTray` | `true` / `true` / `false` | Tray behavior. |
| `keepAlive` | `true` | Holds a hidden `wsl.exe ... sleep infinity` session so WSL does not idle out when you close terminals. `wsl --shutdown` ends it. |
| `statusRefreshSeconds` / `containerRefreshSeconds` / `projectRefreshSeconds` | `3` / `10` / `30` | Refresh intervals. |

## Modes
`modes\balanced.wslconfig`, `coding.wslconfig`, `lightroom.wslconfig` are examples
(memory / processors / swap, `networkingMode=mirrored`, `autoMemoryReclaim=gradual`).
Adjust them to your machine's RAM and CPUs, or add your own - every `*.wslconfig` in `modesDir` is a
mode. Comment lines (`#`) are ignored when matching the current `.wslconfig` against the modes.

## projects.json
Key = folder name under `projectsRoot`. Example (see `src\projects.example.json`):

```json
{
  "groups": ["Active", "Tools", "Archive"],
  "collapsed": ["Archive"],
  "projects": {
    "my-web-app":  { "group": "Active", "mode": "coding", "pinned": true, "url": "http://127.0.0.1:3000",
                     "tools": [ { "name": "Frontend dev server", "command": "npm run dev", "cwd": "frontend", "background": true } ] },
    "api-service": { "group": "Active", "composeDir": "deploy", "services": ["db", "redis"],
                     "warning": "Run starts only the local database and cache." },
    "scratch":     { "hidden": true }
  }
}
```

| Key | Meaning |
|---|---|
| `group`, `order` | Section in the list and position in it (written by drag and drop). |
| `mode` | Mode Run starts WSL in. Omit to use whatever mode WSL is in. |
| `pinned` | Pinned panel + tray "Run project" menu. |
| `hidden` | Not listed (unless Show hidden). |
| `url` | Shows an Open button. |
| `warning` | Text shown on the card. |
| `compose` | `false` = never run compose here; `true` = allow it even for a worktree / shared compose name. |
| `composeDir` | Subfolder holding the compose file. |
| `services` | Only start these compose services. |
| `openVSCode` | Default `true`: Run ends by opening VS Code on the folder. |
| `tools[]` | `name`, `command`, `cwd`, `background`, `stop`, `timeoutSeconds`. One-shot tools must succeed; background tools run detached (`setsid nohup`) with pid files and logs in `~/.cache/devcontrol/run/<project>/` (pid + boot id, so a stale pid after a WSL restart is never killed by mistake). |

Top level: `groups` (order), `collapsed` (folded by default), `_help` (documentation, kept on save).
Click **Reload** after editing.

## Safety rules
- **Never boots WSL by accident.** Every `wsl.exe` call that runs something inside Linux goes through
  one guard that first checks `wsl.exe --list --running` and refuses if the distro is stopped.
  Start/shutdown wait for in-flight Linux queries to finish first. Every call is logged to
  `%LOCALAPPDATA%\DevControl\wsl-calls.log` (`QUERY` = safe, `LINUX`/`BOOT`/`CODE`/`SHUT` = touches the VM).
- **Git worktrees** are detected, grouped under their repo with branch / merged / dirty status
  ("safe to remove"), and never compose'd.
- **Shared compose names**: compose identifies a stack by its `name:`, not its folder. Folders whose
  compose name is used by another folder get no Run unless `projects.json` says `"compose": true`
  for that one folder.
- **Collision guard**: `up` / `restart` is refused if that compose name already has containers from
  a different folder.
- Stop WSL, mode switches and Quit VS Code always ask first.

## Why the launcher is signed
`DevControl.exe` is compiled on your machine, so SmartScreen does not know it and may show the grey
"Windows protected your PC" dialog - and every rebuild changes its hash. `Deploy.ps1 -Sign` creates a
self-signed `CN=KD Dev Tools` code-signing certificate in `Cert:\CurrentUser\My` and trusts it in
**your user's** `Root` and `TrustedPublisher` stores (no admin, nothing machine-wide; Windows asks you
to confirm the Root import). The exe is then signed (SHA256, timestamped when online) and re-signed on
every rebuild. Check with `Get-AuthenticodeSignature DevControl.exe` > `Valid`. Signing is optional.
Remove the certificate with `Uninstall-DevControl.ps1 -RemoveCertificate`.

## Files
| Path | What |
|---|---|
| `src/DevControl.ps1` | UI, async job runner, tray, project Run/Stop/Restart sequences, grouping |
| `src/Core.ps1` | all WSL/Docker/Windows logic (also loaded in background runspaces) |
| `src/MainWindow.xaml` | window layout and styles |
| `src/SelfTest.ps1` | automated UI test (`-SelfTest`) |
| `src/Install.ps1` | build step: icon, compiles + signs `DevControl.exe` |
| `src/Launcher.cs` | no-console launcher source |
| `src/settings.default.json`, `src/projects.example.json` | seeds for `settings.json` / `projects.json` |
| `modes/*.wslconfig` | example modes |
| `Deploy.ps1` / `Uninstall-DevControl.ps1` | install/update / remove |
| `tests/Run-SelfTest.ps1` | runs the self-test against the installed app |
| `docs/fixes.md` | fix log |

Runtime data: `%LOCALAPPDATA%\DevControl\` (`app.log`, `wsl-calls.log`, `projects-cache.json`,
`ui-state.json`, `selftest.log`, `.wslconfig` backups).

## Testing
**Automated:** `tests\Run-SelfTest.ps1` (WSL must be running, `projectsRoot` set, at least two modes).
It clicks through the UI of the installed app (about 5 minutes) using throwaway `zz-devcontrol-selftest*`
fixture folders it creates in `projectsRoot` and removes afterwards, and a temporary `projects.json`.
It never shuts WSL down or quits VS Code (those prompts are answered No), but it pulls `alpine`,
brings a test compose project up and down, and opens a fixture folder and an empty window in VS Code
(close them afterwards). Exit code = number of failures; details in `%LOCALAPPDATA%\DevControl\selftest.log`.

**Manual checklist** (the parts the self-test must not do for real). Close WSL terminals and VS Code
windows you care about first.
1. **Stop WSL** > confirm > the log says `WSL shut down.`, the header shows **WSL: Stopped**, Memory `-`,
   project buttons grey out. The window stays open.
2. Wait 60 s. The header still says **WSL: Stopped** (the app must not wake it). `wsl --list --running`
   says no running distributions; `wsl-calls.log` shows only `QUERY` lines since the `SHUT` line.
3. Pick **coding** > **Start WSL** > log: `Mode set to coding. ... is running. Docker is ready.` The header
   shows `Mode: coding (16GB / 8 CPU)` and Live about 8 CPU.
4. Pick **balanced** > **Start WSL** > a restart prompt appears. **No** changes nothing; **Yes** restarts
   WSL and Live shows 6 CPU.
5. Tray: **Stop WSL** > confirm > stopped; **Start WSL > balanced mode** > running.
6. With WSL stopped, **Run** a pinned project that has a `mode` > WSL starts in that mode, compose comes
   up, VS Code opens; its containers appear nested under the card.
7. **Quit VS Code** > confirm > every VS Code window in WSL closes, the card says *Not running in WSL*,
   WSL and containers keep running. **Open (no folder)** brings back an empty window.
8. `mkdir <projectsRoot>/zz-test` in a WSL terminal > within 30 s **zz-test** appears under **New**.
   `rmdir` it > it disappears.

## Uninstall
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\devcontrol\Uninstall-DevControl.ps1 [-RemoveCertificate] [-RemoveData]
```
Closes a running Dev Control, backs up `settings.json` / `projects.json` to
`%LOCALAPPDATA%\DevControl\uninstall-backup-<date>\`, removes the shortcuts and the install folder.
`-RemoveCertificate` removes `CN=KD Dev Tools` from your `My` / `Root` / `TrustedPublisher` stores;
`-RemoveData` removes the logs in `%LOCALAPPDATA%\DevControl` (backups are kept). `-Destination` if you
installed elsewhere. WSL, your `.wslconfig` and `~/.cache/devcontrol` inside Linux are not touched.
