#!/bin/sh
# setup-linux.sh - Linux side of WSL-Windows-KD-Custom-Setup. Normally run by install.ps1 /
# uninstall.ps1 on Windows, which call it twice: once as root (packages) and once as the user (files).
#
#   sudo ./setup-linux.sh packages    install Linux VS Code (Microsoft apt repo) if missing, plus
#                                     clipboard / audio / font packages
#   ./setup-linux.sh user             install launchers into ~/.local/bin, desktop entries, VS Code argv.json
#   ./setup-linux.sh uninstall-user   remove what "user" installed (packages and argv.json are left alone)
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
}

uninstall_user() {
    for s in $SCRIPTS; do
        if [ -f "$BIN/$s" ] && grep -q "$MARK" "$BIN/$s"; then rm -f "$BIN/$s"; say "removed $BIN/$s"; fi
    done
    if [ -L "$BIN/code" ] && [ "$(readlink "$BIN/code")" = code-linux ]; then rm -f "$BIN/code"; say "removed $BIN/code"; fi
    for d in code.desktop winbrowser.desktop; do
        if [ -f "$APPS/$d" ] && grep -q "$MARK" "$APPS/$d"; then rm -f "$APPS/$d"; say "removed $APPS/$d"; fi
    done
    say "left in place: apt packages, Linux VS Code, ~/.vscode/argv.json settings"
}

check() {
    for s in $SCRIPTS code; do printf '%-16s %s\n' "$s" "$( [ -e "$BIN/$s" ] && echo installed || echo missing)"; done
    printf '%-16s %s\n' "Linux VS Code" "$( [ -x /usr/share/code/bin/code ] && echo installed || echo missing)"
    for p in $PACKAGES; do printf '%-16s %s\n' "$p" "$(dpkg -s "$p" >/dev/null 2>&1 && echo installed || echo missing)"; done
}

case "${1:-}" in
    packages) install_packages ;;
    user) install_user ;;
    uninstall-user) uninstall_user ;;
    check) check ;;
    *) say "usage: $0 packages|user|uninstall-user|check"; exit 2 ;;
esac
