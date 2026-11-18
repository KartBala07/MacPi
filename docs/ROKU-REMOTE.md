# Using a Roku remote with a Raspberry Pi

Short version: **you can't use a Roku *streaming stick* remote.** Not "it's
difficult" — the hardware can't do it. Here is why, and what to buy instead for
about the price of a coffee.

## Why the stick remote won't work

Roku remotes come in three flavours:

| Remote | How it talks to the Roku | Works with a Pi? |
|---|---|---|
| Simple remote (IR-only, old) | Infrared, NEC-ish codes | **Yes**, with an IR receiver |
| Voice / "point anywhere" remote | **Wi-Fi Direct (802.11)**, proprietary pairing | No |
| Voice Remote Pro | Wi-Fi Direct + a private headphone link | No |

The stick-style remotes are RF, not Bluetooth. Roku's pairing is a closed
handshake between the remote and the Roku's own Wi-Fi chip; the remote never
appears as a Bluetooth HID device, and it won't complete pairing with anything
that isn't a Roku. There is no driver to install because there is no standard
protocol on the wire.

Test which one you have: point the remote at a phone camera and press a button.

- **Purple/white flash on the camera** → it has an IR emitter, so it can also
  drive an IR receiver (many voice remotes have IR for TV power/volume only).
- **Nothing** → RF only. It will never talk to a Pi.

## Option 1 — USB air mouse / mini keyboard (recommended)

A 2.4 GHz "air mouse" remote with a USB dongle presents itself as a normal
keyboard + mouse. Nothing to install.

```bash
lsusb                 # after plugging in
xinput list           # it should appear as a keyboard
```

Good for a TV setup because they have arrows, OK, back and a gyro pointer.

## Option 2 — Bluetooth media remote

Fire TV remotes, 8BitDo, and generic Android TV remotes pair as keyboards:

```bash
bluetoothctl
> power on
> scan on
# hold the remote's pairing combo (usually Home for 5-10 s)
> pair XX:XX:XX:XX:XX:XX
> trust XX:XX:XX:XX:XX:XX
> connect XX:XX:XX:XX:XX:XX
```

`trust` matters — without it the remote drops after idle and you have to
re-pair.

## Option 3 — IR receiver on the GPIO header (~$1)

Parts: a **TSOP38238** (or TSOP4838 / VS1838B) 38 kHz IR receiver.

```
TSOP38238            Raspberry Pi
  OUT  ────────────  GPIO17  (pin 11)
  GND  ────────────  GND     (pin 6)
  VS   ────────────  3V3     (pin 1)
```

A 100 nF capacitor across VS/GND helps if you get noise. Then:

```bash
echo 'dtoverlay=gpio-ir,gpio_pin=17' | sudo tee -a /boot/firmware/config.txt
sudo reboot

sudo apt install ir-keytable
ir-keytable                       # should list rc0 with /dev/lirc0

macpi-remote learn-ir             # guided: press each button once
```

`learn-ir` writes `/etc/rc_keymaps/macpi-roku`, applies it immediately, and
enables `macpi-ir.service` so it survives reboots.

Buttons it maps: arrows → arrow keys, OK → Enter, Back → Escape, Home → Super
(opens the app grid), Play/Pause → space.

If a button won't learn, check the receiver sees *anything*:

```bash
sudo ir-keytable -t
# press buttons; you should see "scancode = 0x...."
```

## Option 4 — HDMI-CEC (if the Pi is plugged into a TV)

The TV's remote — including a Roku TV remote — sends CEC commands over HDMI,
and the Pi's HDMI port can receive them.

```bash
sudo apt install cec-utils
macpi-remote cec
```

That maps up/down/left/right/select/exit/home from the TV remote onto the
desktop. Add `~/.config/autostart/macpi-cec.desktop` if you want it at login.

Caveat: CEC is a shared bus. Some TVs stop forwarding keys once they think a
device is "just a PC", and a few cheap HDMI switches block CEC entirely.

## What I'd actually do

If the Pi is going behind a TV: buy the $12 air mouse. It is one plug, it never
disconnects, and it has a pointer for the odd dialog. Keep the Roku remote for
the Roku.
