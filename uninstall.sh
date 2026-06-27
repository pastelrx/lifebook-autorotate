#!/usr/bin/env bash
#
# Uninstaller for lifebook-autorotate. Reverses install.sh.
# Leaves your 'input' group membership and any installed packages alone
# (it prints how to remove those if you want to).
#
set -uo pipefail

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
AUTOSTART_DIR="$HOME/.config/autostart"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

say "Stopping and disabling the service"
systemctl --user disable --now autorotate.service 2>/dev/null || true
rm -f "$UNIT_DIR/autorotate.service"
systemctl --user daemon-reload 2>/dev/null || true

say "Removing PATH symlink"
# only remove if it's our symlink, never a real file someone put there
[ -L "$BIN_DIR/autorotate.sh" ] && rm -f "$BIN_DIR/autorotate.sh"

say "Removing onboard autostart override"
rm -f "$AUTOSTART_DIR/onboard-autostart.desktop"

if command -v gsettings >/dev/null 2>&1; then
    say "Resetting onboard tablet-mode state-file setting"
    gsettings reset org.onboard.auto-show tablet-mode-state-file 2>/dev/null || true
fi

cat <<EOF

Done. Left in place on purpose (remove manually if you want):
  - 'input' group membership:   sudo gpasswd -d "$USER" input
  - packages installed via pacman (iio-sensor-proxy, evtest, ...)
  - other onboard settings (auto-show, start-minimized)
EOF
