# lifebook-autorotate

Automatic screen rotation for convertible laptops on **X11**, with proper
coordinate transformation for the Wacom pen and touchscreen so the stylus keeps
hitting the right spot after the display rotates.

Originally written for a **Fujitsu LIFEBOOK U9313X** running **Manjaro XFCE**,
but it works on any X11 setup that has an accelerometer exposed through
`iio-sensor-proxy` and a Wacom (or similar) touch/pen device.

When you fold the laptop into tablet mode and turn it, the screen follows the
orientation. Pen and touch input are rotated to match, so drawing stays
accurate. Includes a debounce so it doesn't flip while you're just picking the
machine up, and a lock file to pause rotation on demand.

## Features

- Follows the accelerometer and rotates the display automatically
- Transforms Wacom pen + touch coordinates to match the rotation
- Pulls off-screen windows back into view after a rotation (needs `wmctrl`)
- Auto-detects Wacom devices by name (no hardcoded device IDs)
- Debounce: orientation must be stable for ~1s before it flips
- Pause/resume with a lock file
- One-shot mode for forcing or testing a specific orientation

## Requirements

- X11 (this does **not** work on Wayland)
- `iio-sensor-proxy` — exposes the accelerometer
- `xorg-xrandr` — rotates the display
- `xorg-xinput` — transforms pen/touch coordinates
- `wmctrl` — *(optional)* pulls off-screen windows back into view after a
  rotation. If it's missing, rotation still works; stray windows just have to be
  dragged back by hand.

On Arch / Manjaro:

```bash
sudo pacman -S iio-sensor-proxy xorg-xrandr xorg-xinput wmctrl
```

Check that your accelerometer is detected:

```bash
monitor-sensor
```

You should see lines like `Accelerometer orientation changed: normal` when you
tilt the machine. If you do, you're good to go.

## Install

```bash
git clone https://github.com/pastelrx/lifebook-autorotate.git
cd lifebook-autorotate
chmod +x autorotate.sh
```

Test it before wiring up autostart (see below), then either:

### Option A — XFCE autostart (simplest)

`Settings → Session and Startup → Application Autostart → Add`:

- **Name:** Auto-rotate
- **Command:** `/full/path/to/lifebook-autorotate/autorotate.sh`

### Option B — systemd user service

Copy the unit and edit the path inside it to point at where you cloned the repo:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/autorotate.service ~/.config/systemd/user/
# edit ExecStart in that file to the real path
systemctl --user daemon-reload
systemctl --user enable --now autorotate.service
```

Check status / logs:

```bash
systemctl --user status autorotate.service
journalctl --user -u autorotate.service -f
```

## Usage

Run continuously (this is what autostart does):

```bash
./autorotate.sh
```

Force one orientation and exit — useful for **testing the matrices**:

```bash
./autorotate.sh normal
./autorotate.sh left-up
./autorotate.sh right-up
./autorotate.sh bottom-up
```

Pause / resume auto-rotation:

```bash
touch /tmp/autorotate.lock   # pause
rm /tmp/autorotate.lock      # resume
```

## Calibrating the rotation matrices

If after a rotation the **pen lands in the wrong place** — inverted, offset, or
on the wrong axis — the xrandr rotation and the coordinate transformation matrix
for that orientation are out of sync. This is the most common thing to fix and
it's hardware-dependent, so expect to tweak it once.

The fastest way to calibrate is one orientation at a time using one-shot mode.
For the orientation that's wrong, open `autorotate.sh`, find its `case` block in
`apply_rotation()`, and adjust.

Each orientation sets two things that must agree:

- `rot` — the `xrandr --rotate` keyword (`normal`, `left`, `right`, `inverted`)
- `matrix` — the 3×3 coordinate transformation matrix for the pen/touch

The standard matrices are:

| Orientation | xrandr    | Matrix              |
|-------------|-----------|---------------------|
| normal      | `normal`  | `1 0 0 0 1 0 0 0 1` |
| 90° left    | `left`    | `0 -1 1 1 0 0 0 0 1`|
| 90° right   | `right`   | `0 1 0 -1 0 1 0 0 1`|
| 180°        | `inverted`| `-1 0 1 0 -1 1 0 0 1`|

If the pen is rotated 90° the wrong way, swap `left` ⇄ `right` (and their
matrices) between the `left-up` and `right-up` cases. If it's inverted on one
axis only, flip the sign on the relevant matrix entries. The accelerometer's
idea of "left-up" doesn't always map to the same xrandr direction across
machines, which is why this needs a one-time tweak.

## Notes

- Wayland is not supported. On Wayland the compositor handles rotation and tablet
  mapping itself (GNOME does this natively, for example).
- The `Coordinate Transformation Matrix` property only exists on absolute input
  devices (pen/touch). Regular mice are intentionally skipped.
- If you add or remove input hardware, nothing needs changing — devices are
  re-detected each time the script starts.

## License

MIT — see [LICENSE](LICENSE).
