#!/bin/sh
# setup-linux.sh - Linux side of WSL-Windows-KD-Custom-Setup. Normally run by install.ps1 /
# uninstall.ps1 on Windows, which call it twice: once as root (packages) and once as the user (files).
#
#   sudo ./setup-linux.sh packages    install Linux VS Code (Microsoft apt repo) if missing, plus
#                                     clipboard / audio / font packages
#   ./setup-linux.sh user             install launchers into ~/.local/bin, desktop entries, VS Code argv.json
#   ./setup-linux.sh uninstall-user   remove what "user" installed (packages and argv.json are left alone)
#   sudo ./setup-linux.sh journal     keep the Linux system log across WSL restarts and stop chrony
#                                     fighting WSL's own clock sync (FIX-011 in docs/fixes.md)
#   sudo ./setup-linux.sh earlyoom  end a runaway process before the VM thrashes to a standstill (FIX-014)
#                                     and keep VS Code out of swap: vm.swappiness 10 (FIX-016)
#   sudo ./setup-linux.sh uninstall-root   undo "journal" and "earlyoom"
#   ./setup-linux.sh check            print what is installed
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
MARK="WSL-Windows-KD-Custom-Setup"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
SCRIPTS="code-linux code-linux-open winbrowser"

# wl-clipboard: Wayland clipboard tools - the Claude Code CLI reads pasted images with wl-paste, and the
#               Windows-side WSLg Helper hands screenshots to Linux apps with wl-copy.
# xclip:        X11 clipboard fallback used by some CLI tools.
# sox, libsox-fmt-pulse, pulseaudio-utils: a recorder for voice input (Claude Code voice mode) via the
#               WSLg PulseAudio server.
# fonts-noto-*: emoji and wide Unicode coverage for Linux GUI apps.
# xdg-utils:    xdg-mime / xdg-open, so links from Linux apps go to the Windows browser (winbrowser).
PACKAGES="wl-clipboard xclip sox libsox-fmt-pulse pulseaudio-utils fonts-noto-color-emoji fonts-noto-core xdg-utils"

say() { printf '%s\n' "$*"; }

install_packages() {
    [ "$(id -u)" -eq 0 ] || { say "packages: must run as root (sudo)"; exit 1; }
    export DEBIAN_FRONTEND=noninteractive
    need=""
    for p in $PACKAGES; do dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"; done
    if [ ! -x /usr/share/code/bin/code ]; then
        say "packages: adding the Microsoft VS Code apt repository"
        apt-get update -q
        apt-get install -y -q wget gpg apt-transport-https
        install -d -m 0755 /usr/share/keyrings
        wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
        cat >/etc/apt/sources.list.d/vscode.sources <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
        need="$need code"
    fi
    if [ -n "$need" ]; then
        say "packages: installing$need"
        apt-get update -q
        # shellcheck disable=SC2086
        apt-get install -y -q $need
    else
        say "packages: all present"
    fi
}

# argv.json is JSON with comments; only add keys that are missing, never rewrite the file.
ensure_argv_key() { # $1 = key, $2 = JSON value
    f="$HOME/.vscode/argv.json"
    mkdir -p "$HOME/.vscode"
    [ -f "$f" ] || printf '{\n}\n' >"$f"
    if grep -q "\"$1\"" "$f"; then say "argv.json: $1 already set (left as is)"; return; fi
    sed -i "0,/{/s//{\n\t\"$1\": $2,/" "$f"
    # A trailing comma before the closing brace is invalid if the file had no other keys.
    sed -i -z 's/,\n}/\n}/' "$f"
    say "argv.json: set $1 = $2"
}

install_user() {
    [ "$(id -u)" -ne 0 ] || { say "user: run as your normal user, not root"; exit 1; }
    mkdir -p "$BIN" "$APPS"
    for s in $SCRIPTS; do
        install -m 0755 "$HERE/bin/$s" "$BIN/$s"
    done
    # `code` in a terminal gets the same flags. Only replace a symlink or our own file.
    if [ -L "$BIN/code" ] || [ ! -e "$BIN/code" ]; then ln -sfn code-linux "$BIN/code"; fi
    say "user: launchers in $BIN ($SCRIPTS, code -> code-linux)"

    # Desktop entry override so Linux-side launchers (file managers, xdg-open) use code-linux too.
    if [ -f /usr/share/applications/code.desktop ]; then
        { printf '# %s: copy of /usr/share/applications/code.desktop with Exec -> code-linux\n' "$MARK"
          sed -E "s#^Exec=/usr/share/code/code#Exec=$BIN/code-linux#" /usr/share/applications/code.desktop
        } >"$APPS/code.desktop"
        say "user: $APPS/code.desktop"
    fi
    cat >"$APPS/winbrowser.desktop" <<EOF
# $MARK
[Desktop Entry]
Type=Application
Name=Windows default browser
Exec=$BIN/winbrowser %u
NoDisplay=true
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/mailto;text/html;
EOF
    if command -v xdg-mime >/dev/null 2>&1; then
        mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}"
        for t in x-scheme-handler/http x-scheme-handler/https x-scheme-handler/mailto; do
            xdg-mime default winbrowser.desktop "$t" || true
        done
        say "user: http/https/mailto open in the Windows browser"
    else
        say "user: xdg-mime not found - links from Linux apps use \$BROWSER (set by code-linux) only"
    fi

    # Hardware acceleration off (WSLg GPU path glitches); no OS keyring under WSL, so VS Code would
    # otherwise prompt about secret storage on every start.
    ensure_argv_key disable-hardware-acceleration true
    ensure_argv_key password-store '"basic"'

    install_bookmarks
}

# The file dialogs of Linux VS Code (Electron uses the GTK chooser; there is no desktop portal) only
# list $HOME and bookmarks, so the Windows drive was invisible unless you typed /mnt/c (FIX-013).
# Two sidebar entries: the C: drive and the Windows user folder. GTK's bookmarks file has no comment
# syntax, so there is no marker line: uninstall removes exactly the lines bookmark_lines prints.
BOOKMARKS="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"   # GTK 4 reads the same file

uri_path() { printf 'file://%s' "$(printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g')"; }

win_home() {   # Windows user profile as a Linux path, '' if interop is unavailable
    p=$(cd /mnt/c 2>/dev/null && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || p=""
    case "$p" in [A-Za-z]:\\*) wslpath -u "$p" 2>/dev/null ;; esac
}

bookmark_lines() {
    [ -d /mnt/c ] && printf '%s Windows (C:)\n' "$(uri_path /mnt/c)"
    h=$(win_home)
    if [ -n "$h" ] && [ -d "$h" ]; then printf '%s Windows home\n' "$(uri_path "$h")"; fi
    return 0
}

install_bookmarks() {
    mkdir -p "$(dirname "$BOOKMARKS")"
    touch "$BOOKMARKS"
    bookmark_lines | while IFS= read -r line; do
        grep -qxF "$line" "$BOOKMARKS" || printf '%s\n' "$line" >>"$BOOKMARKS"
    done
    say "user: file dialogs show Windows (C:) and Windows home ($BOOKMARKS)"
}

uninstall_bookmarks() {
    [ -f "$BOOKMARKS" ] || return 0
    tmp="$BOOKMARKS.tmp.$$"
    # drop our two entries (matched by label, whatever path they had), keep everything else
    grep -vE '^file://[^ ]+ (Windows \(C:\)|Windows home)$' "$BOOKMARKS" >"$tmp" || true
    if ! cmp -s "$tmp" "$BOOKMARKS"; then mv "$tmp" "$BOOKMARKS"; say "removed Windows bookmarks from $BOOKMARKS"; else rm -f "$tmp"; fi
}

uninstall_user() {
    for s in $SCRIPTS; do
        if [ -f "$BIN/$s" ] && grep -q "$MARK" "$BIN/$s"; then rm -f "$BIN/$s"; say "removed $BIN/$s"; fi
    done
    if [ -L "$BIN/code" ] && [ "$(readlink "$BIN/code")" = code-linux ]; then rm -f "$BIN/code"; say "removed $BIN/code"; fi
    for d in code.desktop winbrowser.desktop; do
        if [ -f "$APPS/$d" ] && grep -q "$MARK" "$APPS/$d"; then rm -f "$APPS/$d"; say "removed $APPS/$d"; fi
    done
    uninstall_bookmarks
    say "left in place: apt packages, Linux VS Code, ~/.vscode/argv.json settings"
}

JOURNALD_CONF=/etc/systemd/journald.conf.d/50-wsl-windows-kd-custom-setup.conf
CHRONY_FLAG=/var/lib/wsl-windows-kd-custom-setup/chrony-disabled

# WSL sets the Linux clock from Windows itself. chrony then steps it back ("System clock interference
# detected"), journald rotates on every backwards jump ("Time jumped backwards, rotating") and its
# 100-file limit deletes earlier boots within hours - the log of a slow/hung session is gone after a restart.
install_journal() {
    [ "$(id -u)" -eq 0 ] || { say "journal: must run as root (sudo)"; exit 1; }
    mkdir -p "$(dirname "$JOURNALD_CONF")"
    cat >"$JOURNALD_CONF" <<EOF
# $MARK: keep the system log across WSL restarts (journalctl -b -1 = previous session).
[Journal]
Storage=persistent
SystemMaxUse=1G
SystemMaxFiles=1000
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    say "journald: persistent, up to 1G ($JOURNALD_CONF)"
    if systemctl is-enabled chrony >/dev/null 2>&1; then
        systemctl disable --now chrony >/dev/null 2>&1
        mkdir -p "$(dirname "$CHRONY_FLAG")"; echo "$MARK" >"$CHRONY_FLAG"
        say "chrony: disabled (WSL keeps the clock in sync with Windows)"
    fi
}

# When Linux runs out of memory the WSL VM does not crash, it thrashes: RAM and swap full, load 100+,
# every vCPU busy reclaiming, wsl.exe cannot even start a process (Wsl/Service/0x8007274c), and the
# kernel OOM killer may never fire because reclaim still makes tiny progress (FIX-014). earlyoom ends
# the worst process early instead. Thresholds: act when available RAM < 5% AND free swap < 50%.
# Never pick VS Code, Claude Code or the WSLg / session plumbing; prefer test scripts and dev servers.
EARLYOOM_DROPIN=/etc/systemd/system/earlyoom.service.d/50-wsl-windows-kd-custom-setup.conf
EARLYOOM_FLAG=/var/lib/wsl-windows-kd-custom-setup/earlyoom-enabled
EARLYOOM_AVOID='^(code|claude|init|systemd|systemd-.*|Xwayland|weston|sshd|dbus-daemon|pulseaudio|earlyoom)$'
EARLYOOM_PREFER='^(python|python3|python3\.[0-9]+|node|workerd|java|pytest)$'

install_earlyoom() {
    [ "$(id -u)" -eq 0 ] || { say "earlyoom: must run as root (sudo)"; exit 1; }
    if ! dpkg -s earlyoom >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom >/dev/null
    fi
    mkdir -p "$(dirname "$EARLYOOM_DROPIN")"
    cat >"$EARLYOOM_DROPIN" <<EOF
# $MARK: end the worst runaway process before the WSL VM thrashes to a standstill (FIX-014).
[Service]
ExecStart=
ExecStart=/usr/bin/earlyoom -m 5 -s 50 -r 3600 --avoid '$EARLYOOM_AVOID' --prefer '$EARLYOOM_PREFER'
EOF
    systemctl daemon-reload
    if ! systemctl is-enabled earlyoom >/dev/null 2>&1; then
        mkdir -p "$(dirname "$EARLYOOM_FLAG")"; echo "$MARK" >"$EARLYOOM_FLAG"
    fi
    systemctl enable earlyoom >/dev/null 2>&1
    systemctl restart earlyoom
    say "earlyoom: running (RAM < 5% and swap < 50% free -> ends the worst process; never VS Code/Claude)"
    install_swappiness
}

# Under swap pressure the kernel (default swappiness 60) pages out idle memory of interactive apps too.
# When Linux VS Code then stalls on swap-in, it stops reading WSLg's Wayland messages, Weston's per-client
# buffer overflows ("libwayland: error in client communication") and WSLg drops the connection - VS Code
# quits and every window and Claude session closes (FIX-016). 10 keeps app memory in RAM and swaps only
# under real need. Applied live, no restart needed.
SYSCTL_CONF=/etc/sysctl.d/60-wsl-windows-kd-custom-setup.conf

install_swappiness() {
    cat >"$SYSCTL_CONF" <<EOF
# $MARK: keep interactive apps (Linux VS Code) in RAM; swap only under real pressure (FIX-016).
vm.swappiness = 10
EOF
    sysctl -q -p "$SYSCTL_CONF"
    say "swappiness: $(cat /proc/sys/vm/swappiness) ($SYSCTL_CONF)"
}

uninstall_root() {
    [ "$(id -u)" -eq 0 ] || { say "uninstall-root: must run as root (sudo)"; exit 1; }
    if [ -f "$SYSCTL_CONF" ] && grep -q "$MARK" "$SYSCTL_CONF"; then
        rm -f "$SYSCTL_CONF"; sysctl -q -w vm.swappiness=60; sysctl -q --system >/dev/null 2>&1 || true
        say "removed $SYSCTL_CONF (swappiness back to $(cat /proc/sys/vm/swappiness))"
    fi
    if [ -f "$EARLYOOM_DROPIN" ] && grep -q "$MARK" "$EARLYOOM_DROPIN"; then
        rm -f "$EARLYOOM_DROPIN"; rmdir "$(dirname "$EARLYOOM_DROPIN")" 2>/dev/null || true
        systemctl daemon-reload; say "removed $EARLYOOM_DROPIN"
        if [ -f "$EARLYOOM_FLAG" ]; then
            systemctl disable --now earlyoom >/dev/null 2>&1 || true; rm -f "$EARLYOOM_FLAG"
            say "earlyoom: disabled again (package left installed)"
        else
            systemctl restart earlyoom 2>/dev/null || true
        fi
    fi
    if [ -f "$JOURNALD_CONF" ] && grep -q "$MARK" "$JOURNALD_CONF"; then
        rm -f "$JOURNALD_CONF"; systemctl restart systemd-journald 2>/dev/null || true; say "removed $JOURNALD_CONF"
    fi
    if [ -f "$CHRONY_FLAG" ]; then
        systemctl enable --now chrony >/dev/null 2>&1 || true
        rm -rf "$(dirname "$CHRONY_FLAG")"; say "chrony: enabled again"
    fi
}

check() {
    for s in $SCRIPTS code; do printf '%-16s %s\n' "$s" "$( [ -e "$BIN/$s" ] && echo installed || echo missing)"; done
    printf '%-16s %s\n' "Linux VS Code" "$( [ -x /usr/share/code/bin/code ] && echo installed || echo missing)"
    printf '%-16s %s\n' "journal kept" "$( [ -f "$JOURNALD_CONF" ] && echo installed || echo missing)"
    printf '%-16s %s\n' "earlyoom" "$(systemctl is-active earlyoom 2>/dev/null || true)"
    printf '%-16s %s\n' "swappiness" "$(cat /proc/sys/vm/swappiness)$( [ -f "$SYSCTL_CONF" ] && echo ' (set by setup)' )"
    printf '%-16s %s\n' "Win bookmarks" "$(grep -qE ' Windows \(C:\)$' "$BOOKMARKS" 2>/dev/null && echo installed || echo missing)"
    for p in $PACKAGES; do printf '%-16s %s\n' "$p" "$(dpkg -s "$p" >/dev/null 2>&1 && echo installed || echo missing)"; done
}

case "${1:-}" in
    packages) install_packages ;;
    user) install_user ;;
    uninstall-user) uninstall_user ;;
    journal) install_journal ;;
    earlyoom) install_earlyoom ;;
    uninstall-root) uninstall_root ;;
    check) check ;;
    *) say "usage: $0 packages|user|journal|earlyoom|uninstall-user|uninstall-root|check"; exit 2 ;;
esac
