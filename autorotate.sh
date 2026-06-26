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

# --- continuous mode ----------------------------------------------------------
echo "Auto-rotate running. Display: $DISPLAY_NAME"
echo "Wacom devices: ${WACOM[*]:-none found}"
echo "Pause with: touch $LOCKFILE   Resume with: rm $LOCKFILE"

LAST=""

# stdbuf forces line-buffered output; without it monitor-sensor buffers its
# output and the pipe receives nothing until a large chunk accumulates.
#
# Note: monitor-sensor emits a line only WHEN the orientation changes, not
# continuously, so we act on each change immediately rather than waiting for a
# repeated reading (there won't be one while the device sits still).
stdbuf -oL -eL monitor-sensor 2>&1 | while read -r line; do
    # skip while paused
    [ -f "$LOCKFILE" ] && continue

    if [[ "$line" =~ orientation\ changed:\ ([a-z-]+) ]]; then
        new="${BASH_REMATCH[1]}"

        # ignore undefined readings and no-op repeats
        [ "$new" = "undefined" ] && continue
        [ "$new" = "$LAST" ] && continue

        apply_rotation "$new" && LAST="$new"
    fi
done
