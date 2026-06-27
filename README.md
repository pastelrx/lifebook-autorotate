# lifebook-autorotate

Automatic screen rotation for convertible laptops on **X11**, with proper
coordinate transformation for the Wacom pen and touchscreen so the stylus keeps
hitting the right spot after the display rotates.

Originally written for a **Fujitsu LIFEBOOK U9313X** running **Manjaro XFCE**,
but it works on any X11 setup that has an accelerometer exposed through
`iio-sensor-proxy` and a Wacom (or similar) touch/pen device.

The key behaviour: rotation is **gated to tablet mode**. When you fold the
machine into a tablet the screen follows the accelerometer; in laptop mode the
accelerometer is ignored, so the display won't flip while you're typing on the
physical keyboard. Pen and touch input are rotated to match so drawing stays
accurate. It can also drive [Onboard](https://launchpad.net/onboard)'s on-screen
keyboard so it only auto-pops in tablet mode.

## Features

- Rotates the display automatically, **only in tablet mode** (`SW_TABLET_MODE`)
- In laptop mode the accelerometer is ignored; folding/unfolding applies the
  current orientation / snaps back to normal
- Transforms Wacom pen + touch coordinates to match the rotation
- Pulls off-screen windows back into view after a rotation (needs `wmctrl`)
- Auto-detects the Wacom devices and the tablet-mode switch by capability — no
  hardcoded device IDs or `eventN` numbers
- Writes a state file Onboard can read, to gate its auto-show to tablet mode
- Pause/resume with a lock file; one-shot mode for forcing/testing an orientation

## Requirements

- X11 (this does **not** work on Wayland)
- `iio-sensor-proxy` — exposes the accelerometer (`monitor-sensor`)
- `xorg-xrandr` — rotates the display
- `xorg-xinput` — transforms pen/touch coordinates
- `evtest` — reads the `SW_TABLET_MODE` switch
- Your user in the **`input` group** — to read the tablet-mode switch device
- `wmctrl` — *(optional)* pulls off-screen windows back in after a rotation
- `onboard` — *(optional)* on-screen keyboard, see below

On Arch / Manjaro:

```bash
sudo pacman -S iio-sensor-proxy xorg-xrandr xorg-xinput evtest wmctrl onboard
```

Check the accelerometer is detected (tilt the machine, watch for orientation
lines):

```bash
monitor-sensor
```

## Install

```bash
git clone https://github.com/pastelrx/lifebook-autorotate.git
cd lifebook-autorotate
./install.sh
```

`install.sh` is idempotent and does everything below for you: installs missing
dependencies, adds you to the `input` group, symlinks the script onto your PATH,
enables the systemd user service, and configures Onboard (if installed). If it
adds you to `input`, **reboot** afterwards (see step 1). `./uninstall.sh` reverses
it. Prefer to do it by hand? The manual steps:

**1. Join the `input` group** (so the script can read the tablet switch), then
**reboot** — a relogin alone isn't always enough, because the long-running
`systemd --user` manager caches your group membership until it fully restarts:

```bash
sudo gpasswd -a "$USER" input
# reboot
```

**2. Deploy onto your PATH.** The service runs the script from `~/.local/bin`,
so symlink it there (a symlink means edits to the repo take effect immediately):

```bash
mkdir -p ~/.local/bin
ln -sfn "$PWD/autorotate.sh" ~/.local/bin/autorotate.sh
```

Make sure `~/.local/bin` is on your `PATH`. Test it before wiring autostart:

```bash
autorotate.sh
# look for: Tablet-mode gating: ON (switch: /dev/input/eventN, currently laptop)
```

**3. Enable autostart (systemd user service):**

```bash
mkdir -p ~/.config/systemd/user
cp autorotate.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now autorotate.service
```

Status / logs:

```bash
systemctl --user status autorotate.service
journalctl --user -u autorotate.service -f
```

> The unit binds to `default.target` (not `graphical-session.target`, which is
> often inactive on XFCE) and sets `DISPLAY`/`XAUTHORITY` explicitly. If your
> display isn't `:0`, edit `Environment=DISPLAY=` in the unit. The script waits
> at startup for the switch device to be created by udev, so it survives being
> started early in boot.

### Alternative: XFCE autostart

If you'd rather not use systemd: `Settings → Session and Startup → Application
Autostart → Add`, command `autorotate.sh`. (No automatic restart on crash.)

## How tablet-mode gating works

The script finds the input device exposing `SW_TABLET_MODE` (the "Intel HID
switches" device on the LIFEBOOK) by scanning `/proc/bus/input/devices` for the
switch-capability bit, so the `eventN` number isn't hardcoded. It reads the
current state with `evtest --query` at startup and then watches the accelerometer
(`monitor-sensor`) and the switch (`evtest`) together:

- **laptop mode** → accelerometer ignored
- **fold to tablet** → applies the current orientation
- **unfold** → snaps back to `normal`

To disable gating and rotate on every orientation change (e.g. hardware without
a tablet switch), set `AUTOROTATE_REQUIRE_TABLET=0`.

## On-screen keyboard (Onboard)

Onboard has built-in auto-show (it pops up when you focus a text field, via the
AT-SPI accessibility bus) and built-in tablet-mode detection via a **state
file**. This script writes `1`/`0` to that file on every tablet transition, so
Onboard only auto-shows in tablet mode. Point Onboard at the file once:

```bash
gsettings set org.onboard.auto-show tablet-mode-state-file "$XDG_RUNTIME_DIR/tablet-mode"
# these are usually already the defaults:
gsettings set org.onboard.auto-show enabled true
gsettings set org.onboard.auto-show tablet-mode-detection-enabled true
gsettings set org.gnome.desktop.interface toolkit-accessibility true
```

Onboard must be **running** for auto-show to work, so start it with your session.
If the packaged `/etc/xdg/autostart/onboard-autostart.desktop` doesn't fire on
your DE (it has a GNOME-only condition), drop a user override that runs it
unconditionally, and start it minimized so it doesn't flash at login:

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/onboard-autostart.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Onboard
Exec=onboard
Icon=onboard
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
gsettings set org.onboard start-minimized true
```

The state-file path defaults to `$XDG_RUNTIME_DIR/tablet-mode`; override with
`AUTOROTATE_TABLET_STATE_FILE`. Auto-show needs the AT-SPI bus running — on a
non-GNOME session like XFCE this is normally fine after a clean login; if Onboard
logs `AT-SPI: Unable to open bus connection`, see Troubleshooting.

## Usage

```bash
autorotate.sh                 # run continuously (what autostart does)
autorotate.sh normal          # force one orientation and exit (test matrices)
autorotate.sh left-up         # other args: right-up, bottom-up
touch /tmp/autorotate.lock    # pause auto-rotation
rm /tmp/autorotate.lock       # resume
```

Environment knobs:

| Variable | Default | Effect |
|----------|---------|--------|
| `AUTOROTATE_REQUIRE_TABLET` | `1` | `0` = ignore tablet mode, always rotate |
| `AUTOROTATE_TABLET_STATE_FILE` | `$XDG_RUNTIME_DIR/tablet-mode` | path of the Onboard state file |

## Calibrating the rotation matrices

If after a rotation the **pen lands in the wrong place** — inverted, offset, or
on the wrong axis — the xrandr rotation and the coordinate transformation matrix
for that orientation are out of sync. This is hardware-dependent, so expect to
tweak it once. Use one-shot mode (`autorotate.sh left-up`) on the wrong
orientation, then edit its `case` block in `apply_rotation()`.

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
axis only, flip the sign on the relevant matrix entries.

## Troubleshooting

- **`Tablet-mode gating: OFF` / `eventN not readable`** — your user isn't in the
  `input` group, or the group change hasn't taken effect. Run
  `sudo gpasswd -a "$USER" input` and **reboot** (not just relogin). Verify with
  `id -nG | grep input`.
- **Onboard doesn't pop up** — check the AT-SPI bus:
  `gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress`.
  If Onboard logs `Unable to open bus connection`, a clean logout/login usually
  fixes it; otherwise ensure `/usr/lib/at-spi-bus-launcher` is started in your
  session and you don't have a stray `at-spi2-registryd --use-gnome-session`.
- **Onboard pops up in laptop mode too** — `tablet-mode-state-file` isn't set, or
  the script isn't running to update it. Confirm `cat $XDG_RUNTIME_DIR/tablet-mode`
  flips between `0` and `1` as you fold/unfold.

## Notes

- Wayland is not supported; there the compositor handles rotation and tablet
  mapping itself (GNOME does this natively).
- The `Coordinate Transformation Matrix` property only exists on absolute input
  devices (pen/touch); regular mice are skipped.
- Input hardware is re-detected each time the script starts, so adding/removing
  devices needs no config change.

## License

MIT — see [LICENSE](LICENSE).
