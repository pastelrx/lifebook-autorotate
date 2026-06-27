#!/usr/bin/env bash
#
# Installer for lifebook-autorotate. Idempotent — safe to re-run.
#
# Does:
#   1. installs missing dependencies (Arch/Manjaro: pacman)
#   2. adds you to the 'input' group (to read the tablet-mode switch)
#   3. symlinks autorotate.sh into ~/.local/bin
#   4. installs + enables the systemd user service
#   5. (if onboard is present) configures its tablet-mode auto-show + autostart
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
AUTOSTART_DIR="$HOME/.config/autostart"
STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tablet-mode"
NEED_REBOOT=0

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }

# --- 1. dependencies ----------------------------------------------------------
say "Checking dependencies"
declare -A PKG=(
    [monitor-sensor]=iio-sensor-proxy
    [xrandr]=xorg-xrandr
    [xinput]=xorg-xinput
    [evtest]=evtest
)
missing=()
for cmd in "${!PKG[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("${PKG[$cmd]}")
done
command -v wmctrl  >/dev/null 2>&1 || warn "wmctrl not installed (optional: rescues off-screen windows after rotation)"
command -v onboard >/dev/null 2>&1 || warn "onboard not installed (optional: on-screen keyboard)"

if (( ${#missing[@]} )); then
    if command -v pacman >/dev/null 2>&1; then
        say "Installing required packages: ${missing[*]}"
        sudo pacman -S --needed "${missing[@]}"
    else
        warn "Missing required packages: ${missing[*]} — install them with your package manager, then re-run."
        exit 1
    fi
fi

# --- 2. input group -----------------------------------------------------------
if id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
    say "User already in 'input' group"
else
    say "Adding $USER to 'input' group (sudo)"
    sudo gpasswd -a "$USER" input
    NEED_REBOOT=1
fi

# --- 3. deploy script onto PATH ----------------------------------------------
say "Linking autorotate.sh into $BIN_DIR"
mkdir -p "$BIN_DIR"
chmod +x "$SCRIPT_DIR/autorotate.sh"
ln -sfn "$SCRIPT_DIR/autorotate.sh" "$BIN_DIR/autorotate.sh"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH — add it in your shell rc so 'autorotate.sh' is found." ;;
esac

# --- 4. systemd user service --------------------------------------------------
say "Installing systemd user service"
mkdir -p "$UNIT_DIR"
cp "$SCRIPT_DIR/autorotate.service" "$UNIT_DIR/autorotate.service"
systemctl --user daemon-reload
systemctl --user enable autorotate.service
systemctl --user restart autorotate.service || warn "Service couldn't start now (no X session?); it'll start on next login."

# --- 5. onboard (optional) ----------------------------------------------------
if command -v onboard >/dev/null 2>&1 && command -v gsettings >/dev/null 2>&1 \
   && gsettings list-schemas 2>/dev/null | grep -qx org.onboard; then
    say "Configuring onboard tablet-mode auto-show"
    gsettings set org.onboard.auto-show tablet-mode-state-file "$STATE_FILE"
    gsettings set org.onboard.auto-show tablet-mode-detection-enabled true
    gsettings set org.onboard.auto-show enabled true
    gsettings set org.onboard start-minimized true
    gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || \
        warn "couldn't enable toolkit-accessibility — onboard auto-show needs the AT-SPI bus"

    say "Adding onboard to session autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "$AUTOSTART_DIR/onboard-autostart.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Onboard
Comment=On-screen keyboard (auto-shows on input focus in tablet mode)
Exec=onboard
Icon=onboard
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
fi

# --- done ---------------------------------------------------------------------
say "Install complete."
if (( NEED_REBOOT )); then
    warn "You were just added to 'input': REBOOT (not just relogin) so the service"
    warn "can read the tablet switch. Until then it runs in always-rotate mode."
fi
