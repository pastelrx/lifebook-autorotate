#!/bin/bash
#
# Auto-rotate screen + Wacom digitizer based on accelerometer.
# For Fujitsu LIFEBOOK U9313X (convertible) on Manjaro XFCE / X11.
#
# Requires: iio-sensor-proxy, xrandr, xinput
#
# Usage:
#   ./autorotate.sh            run continuously, follow accelerometer
#   ./autorotate.sh normal     force a specific orientation once and exit
#   ./autorotate.sh left-up    (other valid args: right-up, bottom-up)
#
# To pause auto-rotation temporarily, create the lock file:
#   touch /tmp/autorotate.lock
# To resume:
#   rm /tmp/autorotate.lock
#

LOCKFILE="/tmp/autorotate.lock"

# --- detect primary display ---------------------------------------------------
DISPLAY_NAME=$(xrandr --query | awk '/ connected/{print $1; exit}')

if [ -z "$DISPLAY_NAME" ]; then
    echo "ERROR: could not detect a connected display via xrandr" >&2
    exit 1
fi

# --- detect Wacom devices automatically ---------------------------------------
# Grabs every xinput device with "Wacom" in the name so we don't hardcode IDs.
mapfile -t WACOM < <(xinput list --name-only 2>/dev/null | grep -i "wacom")

# --- pull off-screen windows back into view -----------------------------------
# When the resolution changes (landscape <-> portrait), windows that were near
# the far edges can end up partly or fully outside the new screen bounds. XFCE
# doesn't reposition them on its own, so after each rotation we walk every
# normal window and nudge any that overflow back inside.
#
# Requires wmctrl. If it isn't installed, this is skipped silently and rotation
# still works; you just keep dragging stray windows by hand.

nudge_windows_onscreen() {
    command -v wmctrl >/dev/null 2>&1 || return 0

    # current screen size after the rotation has applied
    local screen sw sh
    screen=$(xrandr --query | awk '/ connected/{for(i=1;i<=NF;i++) if($i ~ /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/){print $i; exit}}')
    sw=${screen%%x*}
    local rest=${screen#*x}
    sh=${rest%%+*}

    [ -z "$sw" ] || [ -z "$sh" ] && return 0

    # wmctrl -lG columns: winid desktop x y w h ...
    wmctrl -lG | while read -r wid desktop x y w h _; do
        # skip sticky/panel-type windows that wmctrl marks on desktop -1
        [ "$desktop" = "-1" ] && continue

        local nx=$x ny=$y changed=0

        # if window is wider/taller than the screen, clamp size first
        if (( w > sw )); then w=$sw; changed=1; fi
        if (( h > sh )); then h=$sh; changed=1; fi

        # push back inside the right / bottom edges
        if (( nx + w > sw )); then nx=$(( sw - w )); changed=1; fi
        if (( ny + h > sh )); then ny=$(( sh - h )); changed=1; fi

        # and inside the left / top edges
        if (( nx < 0 )); then nx=0; changed=1; fi
        if (( ny < 0 )); then ny=0; changed=1; fi

        if (( changed )); then
            # -e gravity,x,y,w,h  (gravity 0 = default, -1 keeps a dimension)
            wmctrl -i -r "$wid" -e "0,$nx,$ny,$w,$h" 2>/dev/null
        fi
    done
}

# --- rotation logic -----------------------------------------------------------
# Each orientation sets BOTH the xrandr rotation AND the matching coordinate
# transformation matrix for the touch/pen devices.
#
# If pen/touch ends up inverted or offset after a rotation, swap the xrandr
# rotation keyword (left <-> right) for that case; the matrix and the keyword
# must agree.

apply_rotation() {
    local orientation="$1"
    local rot matrix

    case "$orientation" in
        normal)
            rot="normal"
            matrix="1 0 0 0 1 0 0 0 1"
            ;;
	left-up)
            rot="left"
            matrix="0 -1 1 1 0 0 0 0 1"
            ;;
        right-up)
            rot="right"
            matrix="0 1 0 -1 0 1 0 0 1"
            ;;
        bottom-up)
            rot="inverted"
            matrix="-1 0 1 0 -1 1 0 0 1"
            ;;
        *)
            return 1
            ;;
    esac

    xrandr --output "$DISPLAY_NAME" --rotate "$rot"

    for dev in "${WACOM[@]}"; do
        xinput set-prop "$dev" "Coordinate Transformation Matrix" $matrix 2>/dev/null
    done

    # give X a moment to settle on the new resolution, then rescue stray windows
    sleep 0.4
    nudge_windows_onscreen

    echo "rotated -> $orientation (xrandr: $rot)"
}

# --- one-shot mode ------------------------------------------------------------
# If an orientation is passed as an argument, apply it once and exit.
if [ -n "$1" ]; then
    apply_rotation "$1" || echo "Unknown orientation: $1 (use normal|left-up|right-up|bottom-up)" >&2
    exit 0
fi

# --- tablet-mode gating -------------------------------------------------------
# In laptop mode the screen should NOT follow the accelerometer (you don't want
# it flipping while typing on the physical keyboard). We only rotate when the
# convertible is folded into tablet mode, reported by SW_TABLET_MODE on the
# "Intel HID switches" input device.
#
# Set AUTOROTATE_REQUIRE_TABLET=0 to disable gating and always rotate (e.g. on
# hardware without a tablet switch).

REQUIRE_TABLET="${AUTOROTATE_REQUIRE_TABLET:-1}"

# State file consumed by onboard's built-in tablet-mode detection
# (org.onboard.auto-show tablet-mode-state-file). We write "1" in tablet mode
# and "0" in laptop mode; onboard's tablet-mode-state-file-pattern ('1') matches
# only the tablet value, so onboard auto-shows on input focus ONLY in tablet
# mode. Lives on tmpfs in the user runtime dir.
STATE_FILE="${AUTOROTATE_TABLET_STATE_FILE:-${XDG_RUNTIME_DIR:-/tmp}/tablet-mode}"

write_tablet_state() {
    printf '%s\n' "$1" > "$STATE_FILE" 2>/dev/null
}

# Locate the input event device that carries SW_TABLET_MODE. We parse
# /proc/bus/input/devices in paragraph mode and pick the block whose switch
# bitmask (B: SW=) has bit 1 (SW_TABLET_MODE = 2) set, then read its eventN
# handler. This survives eventN renumbering across boots.
find_switch_dev() {
    awk '
        BEGIN { RS=""; FS="\n" }
        {
            ev=""; sw=0
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^H: Handlers=/ && match($i, /event[0-9]+/))
                    ev = substr($i, RSTART, RLENGTH)
                if ($i ~ /^B: SW=/) { v = $i; sub(/^B: SW=/, "", v); sw = strtonum("0x" v) }
            }
            if (ev != "" && and(sw, 2)) { print "/dev/input/" ev; exit }
        }' /proc/bus/input/devices
}

# Read the CURRENT tablet state (not an event): evtest --query exits 10 when the
# switch is active, 0 when inactive. Any other (error) code -> assume laptop.
read_tablet_state() {
    [ -n "$SWITCH_DEV" ] || { echo 0; return; }
    evtest --query "$SWITCH_DEV" EV_SW SW_TABLET_MODE >/dev/null 2>&1
    [ "$?" = "10" ] && echo 1 || echo 0
}

# At boot (as a service) we can start before udev has created and permissioned
# the switch device, which would make us fall back to legacy mode for the whole
# session. Wait briefly for it to appear AND become readable before deciding.
SWITCH_DEV=$(find_switch_dev)
if [ "$REQUIRE_TABLET" = "1" ]; then
    for _ in $(seq 1 30); do
        [ -n "$SWITCH_DEV" ] && [ -r "$SWITCH_DEV" ] && break
        sleep 0.5
        SWITCH_DEV=$(find_switch_dev)
    done
fi

if [ "$REQUIRE_TABLET" = "1" ] && [ -n "$SWITCH_DEV" ] && [ -r "$SWITCH_DEV" ]; then
    GATING=1
    TABLET=$(read_tablet_state)
    write_tablet_state "$TABLET"      # seed onboard's state file at startup
else
    GATING=0
    TABLET=1            # treat as always-in-tablet -> legacy always-rotate
    if [ "$REQUIRE_TABLET" = "1" ] && [ -n "$SWITCH_DEV" ] && [ ! -r "$SWITCH_DEV" ]; then
        echo "WARNING: $SWITCH_DEV not readable; tablet-mode gating disabled." >&2
        echo "         Add your user to the 'input' group and re-login:" >&2
        echo "             sudo gpasswd -a $USER input" >&2
        echo "         Until then the screen rotates regardless of tablet mode." >&2
    fi
    SWITCH_DEV=""       # don't start the switch watcher
fi

# --- rotation handlers --------------------------------------------------------
LAST_ACCEL=""          # latest orientation seen (tracked even in laptop mode)
LAST_APPLIED=""        # last orientation actually applied (dedup)

handle_accel() {
    local new="$1"
    [ "$new" = "undefined" ] && return
    LAST_ACCEL="$new"
    [ "$TABLET" = "1" ] || return            # ignore tilt in laptop mode
    [ "$new" = "$LAST_APPLIED" ] && return
    apply_rotation "$new" && LAST_APPLIED="$new"
}

handle_switch() {
    write_tablet_state "$1"           # let onboard gate its auto-show
    if [ "$1" = "1" ]; then
        TABLET=1
        echo "tablet mode ON"
        # No fresh accel event fires on the fold itself, so apply the current
        # known orientation now.
        if [ -n "$LAST_ACCEL" ] && [ "$LAST_ACCEL" != "$LAST_APPLIED" ]; then
            apply_rotation "$LAST_ACCEL" && LAST_APPLIED="$LAST_ACCEL"
        fi
    else
        TABLET=0
        echo "tablet mode OFF -> normal"
        if [ "$LAST_APPLIED" != "normal" ]; then
            apply_rotation normal && LAST_APPLIED="normal"
        fi
    fi
}

# --- continuous mode ----------------------------------------------------------
echo "Auto-rotate running. Display: $DISPLAY_NAME"
echo "Wacom devices: ${WACOM[*]:-none found}"
if [ "$GATING" = "1" ]; then
    echo "Tablet-mode gating: ON (switch: $SWITCH_DEV, currently $([ "$TABLET" = 1 ] && echo tablet || echo laptop))"
else
    echo "Tablet-mode gating: OFF (rotating on every orientation change)"
fi
echo "Pause with: touch $LOCKFILE   Resume with: rm $LOCKFILE"

# stdbuf + sed -u force line-buffering end to end; without it monitor-sensor and
# evtest buffer their output and the pipe stalls until a large chunk accumulates.
#
# Both event sources are merged into one loop with a tag prefix (ACCEL / SWITCH)
# so a single reader handles orientation changes AND tablet-mode transitions
# without a second process or a shared state file.
#
# Note: monitor-sensor emits a line only WHEN the orientation changes, not
# continuously, so we act on each change immediately.
{
    stdbuf -oL -eL monitor-sensor 2>&1 | sed -u 's/^/ACCEL /' &
    [ -n "$SWITCH_DEV" ] && stdbuf -oL -eL evtest "$SWITCH_DEV" 2>/dev/null | sed -u 's/^/SWITCH /' &
} | while read -r tag rest; do
    # skip while paused
    [ -f "$LOCKFILE" ] && continue

    case "$tag" in
        ACCEL)
            [[ "$rest" =~ orientation\ changed:\ ([a-z-]+) ]] && handle_accel "${BASH_REMATCH[1]}"
            ;;
        SWITCH)
            [[ "$rest" =~ SW_TABLET_MODE\),\ value\ ([0-9]+) ]] && handle_switch "${BASH_REMATCH[1]}"
            ;;
    esac
done
