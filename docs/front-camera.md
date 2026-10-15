# Front camera: Sony IMX241 driver

Status: **working.** With the DKMS package (kernel patches 0004 to 0006) the
front camera comes up on every normal boot next to the rear camera, and it
streams at 2592x1944 and 1296x972, 30 fps. Applications see it through the
patched libcamera (`libcamera/patches/0005` to `0008`) as
"Internal front camera". Stock libcamera 0.7.2 has no IMX241 sensor helper and
skips this camera ("Failed to create camera sensor helper for imx241") while
still offering the rear one.

This document describes the driver. The chronological bring-up, including
the missing VSIO rail that made early power-ups fail, is in
[`hardware.md`](hardware.md); the Windows driver analysis it is based on is in
[`imx241-windows-re.md`](imx241-windows-re.md).

| | |
|---|---|
| Sensor | Sony IMX241, 5 MP (2592x1944 active), 1.12 µm, type 1/5, SMIA 1.0, model ID 0x0241 |
| ACPI | `\_SB.PCI0.LNK1`, HID `INT347F`, module FN50FF-562H, SSDB rotation 0 |
| Bus | `i2c-INT347F:00`, I2C3, address 0x37 |
| CSI-2 | IPU3 port 1, 2 lanes, RAW10, native order RGGB (reg 0x0006), black level 64 (reg 0x0008) |
| Power | TPS68470 (shared with the rear OV8858): VSIO "vsio" 1.8 V (sensor I2C/IO switch, shared with the rear camera), VAUX1 "vcore" 1.053 V, VAUX2 "vio" 1.8 V, GPIO4 "avdd-enable" (external 2.8 V), GPIO5 "reset", GPIO6 "powerdown" (both active low). GPIO3 (VCM) is not used: fixed focus. GPIO1/2 are the I2C daisy chain and are never touched. |

Files:

| File | What |
|---|---|
| `src/drivers/media/i2c/imx241.c` | the driver (new file) |
| `patches/0005-media-i2c-Add-driver-for-Sony-IMX241.patch` | the same file as a new-file patch, applied by `prepare.sh` |
| `patches/0004-…-front-camera.patch` | PMIC board data: supplies and GPIOs for `i2c-INT347F:00` |
| `patches/0006-…IMX241….patch` | ipu-bridge entry, link frequency 498 MHz |
| `libcamera/patches/0005`, `0006` | libcamera sensor helper (gain model, black level) and sensor properties |
| `libcamera/patches/0007`, `0008` | IPU3 AGC uses the sensor digital gain; IMX241 tuning file (AGC target 0.32) |
| `scripts/front-test.sh`, `scripts/front-test-restore.sh` | developer tooling: raw capture outside libcamera, one-off test boots |
| `tools/raw2png.py` | PNG preview of an IPU3-packed raw capture |

## Driver design

Single V4L2 subdev (`MEDIA_ENT_F_CAM_SENSOR`, one source pad), CCI regmap helpers,
subdev active state, runtime PM (1 s autosuspend), `INT347F` ACPI match (no
device tree binding yet). Modelled on upstream `imx219.c`.

Why not the generic `ccs` driver: the sensor leaves the clock frequency limit
registers empty, reports a wrong pixel array (1936x1096), takes its VT dividers in
manufacturer registers 0x3037/0x3038 (the standard 0x0301/0x0303 are never written by
Windows), clocks two pixels per VT clock, and needs manufacturer register writes in
every mode.

### Modes

Both modes read out the whole 2592x1944 array (crop = native size = crop bounds).

| Mode | Source | LLP (0x0342) | FLL default | Readout regs | fps @24 MHz / @19.2 MHz |
|---|---|---|---|---|---|
| 2592x1944 | Windows table A | 1456 | 2280 | 0387=1, 3048=20, 3165=20 | 30.00 / 30.07 |
| 1296x972 2x2 binned | readout of tables C/D, timing of table F | 1600 | 2076 | 0387=3, 3048=25, 3165=28 | 29.99 / 30.06 |

Every mode writes the full Windows register list in Windows order (0101, 303c, 303d,
3041, 30e0, 30e1, 30f6=20, 34ce, FLL, LLP, window, increments, 3048, 30d5, 3165, 30d1,
30d0, 3102, 3103, 3049, 304d, 304c, 0112/0113 RAW10, output size), then the PLL
(0305, 0307), then 3037=0a, 3038=01, 303e=01, 30a2=0e, 30a5=61, 30a7=40, 31aa=02,
3301=00, 3318=60, 0204=00. Exposure, gains, frame length, flips and test pattern are
then written from the controls.

The binned mode does not use Windows table D as is: D runs the PLL at 345.6 MHz
(below the sensor's 384 MHz minimum) with a 172.8 MHz link frequency, which would need
a second link frequency in ipu-bridge and has no 24 MHz equivalent. Table F (Windows,
26 MHz clock) shows the binned readout at a PLL of about 1 GHz with LLP 1600 and the
same rate-dependent values as the full mode, so the binned mode uses one PLL and one
link frequency with the full mode. 30f6 is 0x20 as in tables A/C/D (this module);
F has 0x00 but belongs to another module.

Binned timing caveat: tables C/D program a frame length (570/790) below the 972 output
lines, which suggests the sensor outputs two binned rows per line period in this mode.
The driver's timing model (line period = LLP / vt_pix, V4L2 lines = line periods) gives
correct frame time and exposure time either way; it only forbids frame lengths
below 972 + 6 lines, i.e. caps the binned mode at about 62 fps, which is harmless.

### Timing model and controls

```
pll        = ext_clk / pre_pll_div (0x0305) * pll_mult (0x0307)
vt_pix_clk = pll / 10 (0x3037) / 1 (0x3038)
pixel_rate = 2 * vt_pix_clk                      (2 pixels per VT clock)
link_freq  = pll / 2;  pixel_rate = link_freq * 2 * 2 lanes / 10 bits
line       = 2 * LLP pixels  ->  HBLANK = 2 * LLP - width   (read-only)
VBLANK     = FLL - height, min 6 (sensor limit), max 65535 - height
```

| Control | Register | Range |
|---|---|---|
| `EXPOSURE` | 0x0202 (lines) | 1 .. FLL - 5, default FLL - 5 (as Windows) |
| `ANALOGUE_GAIN` | 0x0205 | 0 .. 224, gain = 256 / (256 - code) |
| `DIGITAL_GAIN` | 0x020e/0210/0212/0214 | 0x0100 (1.0) .. 0x0fff |
| `VBLANK` | 0x0340 = height + vblank | see above |
| `HBLANK`, `PIXEL_RATE`, `LINK_FREQ` | — | read-only |
| `HFLIP`, `VFLIP` | 0x0101 bits 0/1 (read-modify-write) | locked while streaming; Bayer code RGGB / GRBG / GBRG / BGGR |
| `TEST_PATTERN` | 0x0600 (SMIA) | Disabled, Solid Colour, Colour Bars, Fade to Grey, PN9 |
| orientation, rotation | firmware (ipu-bridge from SSDB/_PLD) | — |

Exposure, analogue and digital gain form a control cluster and are written together
inside a group hold (0x0104), as Windows does; VBLANK is written under its own hold.

## Clock handling

The TPS68470 has one clock output, shared by both cameras. It starts at 19.2 MHz;
the rear camera's ov8858 probe sets it to 24 MHz. The provider has `CLK_SET_RATE_GATE`:
its rate cannot change while any consumer has it prepared (set_rate returns -EBUSY).

Rules in the driver (a design choice):

- Read `clk_get_rate()`. If it is 24 MHz or 19.2 MHz, use it as is; never change a
  supported rate.
- Otherwise request 24 MHz; if the rate is still unsupported, fail the probe with
  "clock rate … not supported".
- Check the rate again at every stream start (the clock is prepared then, so it can't
  change underneath) and switch PLL settings, `LINK_FREQ` and `PIXEL_RATE` if it
  changed while the sensor was off (e.g. imx241 probed at the initial 19.2 MHz,
  then ov8858 set 24 MHz). An unsupported rate at that point fails `STREAMON`.
- The driver does **not** use `devm_v4l2_sensor_clk_get()` for a real clock: on ACPI
  it sets the clock to the firmware "clock-frequency" (19.2 MHz from SSDB), which would
  re-tune the shared clock under the rear camera. It only falls back to it when there
  is no clock provider (it then registers a fixed clock).
- Probe powers the sensor down synchronously after reading the ID (no autosuspend
  window), so ov8858's probe never finds the clock prepared by imx241.

| ext clk | pre_pll_div | mult | PLL | vt_pix | pixel rate | link freq | lane rate |
|---|---|---|---|---|---|---|---|
| **24 MHz** | 2 (12 MHz) | 83 | 996 MHz | 99.6 MHz | 199.2 Mpix/s | **498 MHz** | 996 Mbit/s |
| 19.2 MHz (Windows A) | 2 (9.6 MHz) | 104 | 998.4 MHz | 99.84 MHz | 199.68 Mpix/s | 499.2 MHz | 998.4 Mbit/s |

In practice the rear camera's probe sets the shared clock to 24 MHz at boot,
so the front camera runs at 24 MHz; the 19.2 MHz settings have not been
exercised on hardware.

Checks for 24 MHz: PLL input 12 MHz (limit 6–27), multiplier 83 (16–255), PLL 996 MHz
(384–1000), vt_pix 99.6 MHz (≤ 100). Full mode: line 1456 / 99.6 MHz = 14.618 µs,
frame 2280 lines = 33.33 ms = 30.00 fps. A 2592-pixel RAW10 line on 2 lanes needs
12960 bit per lane in 14.618 µs = 886.6 Mbit/s, i.e. 89 % of 996 Mbit/s, the same margin
as Windows table A (888.7 of 998.4).

Rate-dependent registers: 30a2=0e, 31aa=02, 3318=60 are identical in Windows tables
A (998.4 MHz), B (960 MHz), E and F (996.67 MHz), so they are valid at 996 MHz. **30a5
is not:** A/B use 0x61, E/F (26 MHz clock, PLL input 8.67 MHz) use 0x60. Its low bit seems
to follow the PLL input or external clock rather than the PLL output, and Windows has no
point with a 12 MHz PLL input. The driver uses 0x61 (this module's value), and both modes
stream cleanly with it at 24 MHz.

The ipu-bridge entry (0006) lists 498 MHz. The driver checks the firmware
`link-frequencies` with `v4l2_link_freq_to_bitmap()`: it fails if none of its two
frequencies is listed, and warns if the one for the current clock is not (at 19.2 MHz,
499.2 MHz vs. 498 MHz, a 0.24 % difference that the CIO2 receiver timing doesn't notice).
ov8858 itself does no such check (it ignores the firmware list).

## Power sequencing

As Windows (`VoltageUF`, CLDB[14] = 0, plus the common `IoActive` step that turns on
VSIO for every sensor):

0. at least 100 ms since the last power-off (the rails are not actively discharged, so
   this gives the sensor a clean power-on reset), then `vsio` (TPS68470 VSIO, 1.8 V,
   optional supply; shared with and refcounted against the rear camera)
1. analogue: optional `avdd` regulator on, `avdd-enable` GPIO (TPS68470 GPIO4) high, 1–2 ms
2. `vio` (VAUX2, 1.8 V), then `vcore` (VAUX1, 1.053 V)
3. clock on, 1–2 ms
4. `reset` and `powerdown` released (GPIO5/6), 20 ms
5. I2C: ID check (probe); on stream start: soft reset (0x0103 = 1), 1–2 ms, standby,
   mode table, PLL, common registers, controls (flip read-modify-write of 0x0101),
   stream on (0x0100 = 1)

Power-off is the reverse. All GPIO accesses use the `_cansleep` variants (TPS68470
GPIOs are behind I2C). `reset`, `powerdown` and `avdd-enable` are optional GPIOs;
`vio` and `vcore` are required regulators (ACPI platforms get no dummy regulators).

Without VSIO the sensor NACKs on I2C unless the rear camera happens to be powered at the
same time; that was the cause of the intermittent failures during bring-up.

### GPIO4 as a regulator (open item)

Upstream-proper would be for the board data to describe the external 2.8 V regulator
as a regulator ("avdd" for `i2c-INT347F:00`), with GPIO4 as its enable, instead of
handing a GPIO to the sensor driver. The int3472 code has a helper for exactly that
(`skl_int3472_register_regulator()` in `clk_and_regulator.c`, used by the discrete
INT3472 driver for GPIO-type regulators), but it takes a `struct int3472_discrete_device`;
the TPS68470 path would need it refactored to take a device, a GPIO descriptor and
consumer names, and to register it after the tps68470-gpio cell exists (or a
`regulator-fixed` platform device with a GPIO lookup on "tps68470-gpio" 4). For now the
driver requests an optional `avdd-enable` GPIO (provided by patch 0004) and also accepts
an optional `avdd` regulator, so the board data can switch to the proper way later
without a driver change.

## Testing

Normal use needs nothing beyond the installation steps in the
[README](../README.md#installation): after a reboot with the DKMS package,

```sh
journalctl -k -b | grep -i imx241    # "Sony IMX241 rev 0x00, 24000000 Hz clock, link frequency 498000000 Hz"
cam -l                               # with the patched libcamera: two cameras, LNK0 (rear) and LNK1 (front)
qcam                                 # pick the front camera
```

`cam`/`qcam` need exclusive access, so stop PipeWire first:
`systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber`
(start it again afterwards).

### Raw capture without libcamera (developer tooling)

`scripts/front-test.sh` captures raw frames straight from the CIO2 with
`media-ctl`/`v4l2-ctl` (colour-bar test pattern, then a real image) and writes
PNG previews with `tools/raw2png.py` (needs numpy, see `tools/lsc/README.md`).
It was written before the ipu-bridge entry (now 0006) was enabled by default and therefore runs in a
one-off *test boot*:

ipu-bridge builds the sensor fwnode graph once, on the first ipu3-cio2 probe
of a boot, and attaches it to the CIO2 device as a secondary fwnode that
outlives the module. A reloaded ipu-bridge (`ipu_bridge_init()` →
`ipu_bridge_check_fwnode_graph()`) sees the existing graph and returns without
changing it, and ipu3-cio2 only exposes its media graph once every sensor in
that graph has bound. So `scripts/front-test.sh arm` installs modprobe.d
`install` rules that load a separately built ipu-bridge and imx241 (from
`build/front/`) **only** when the kernel command line contains
`hpcam_front_test`; boots without the flag load the normal DKMS modules. This
is still useful to try a modified driver without reinstalling the package:

```sh
scripts/front-test.sh                 # as user: builds build/front/{ipu-bridge,imx241}.ko
sudo scripts/front-test.sh arm        # stages them in /var/lib/hp-x2-612-g2-camera/front-test
                                      # and writes /etc/modprobe.d/hp-x2-612-g2-camera-front-test.conf
```

Reboot, edit the boot entry once and append `hpcam_front_test` to the kernel
command line (systemd-boot: `e`; GRUB: `e`, end of the `linux` line, Ctrl-X).
In that boot:

```sh
systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
sudo scripts/front-test.sh run                    # full resolution
sudo SIZE=1296x972 scripts/front-test.sh run      # binned mode
sudo EXPOSURE=1000 AGAIN=128 scripts/front-test.sh run   # optional: own exposure / 2x gain
sudo scripts/front-test.sh reload                 # after rebuilding imx241.ko: swap it in
```

`run` prints module and device state, deferred probes, the filtered kernel log
and the media topology, configures `imx241 → ipu3-csi2 1 → ipu3-cio2 1`, and
writes `captures/front-<time>/{bars,image}.{raw,png}`. `bars.png` should show
vertical SMIA colour bars.

Afterwards run `sudo scripts/front-test-restore.sh` (removes the modprobe.d
file and the staged modules) and reboot normally. If imx241 did not bind in
the test boot, the rear camera is unavailable until that reboot.

## Open items and risks

- **Low sensitivity.** In dim light the AGC reaches the 33 ms / 8x analogue gain limit;
  libcamera 0007 adds up to 4x sensor digital gain (keeping 30 fps), and 0008 raises the
  AGC target to 0.32. Expect noise in dim rooms.
- **No lens shading correction or colour calibration** for this sensor (the IMX241 tuning
  file only sets the AGC target).
- **Mirroring:** checked with a text test in qcam: the default image is unmirrored (correct for a raw camera image; apps mirror the self-view themselves).
- **Binned mode** is not a Windows operating point for this module (table F belongs to the
  26 MHz "START2FRONT" module); its rate-dependent registers are shared with the full mode.
  It streams correctly on this tablet.
- **Bayer order with flips** assumes the sensor does not shift its readout to keep RGGB
  (as on other Sony SMIA sensors). Flips are off by default (SSDB rotation 0, Windows doesn't
  flip either) and have not been tested; verify with `v4l2-ctl -c horizontal_flip=1` before
  relying on them.
- **Pixel array**: a distributor spec lists 2608x1960 total pixels around the 2592x1944 active
  area; the driver only exposes the 2592x1944 window Windows programs.
- **19.2 MHz clock** settings are derived from Windows table A but untested (see the clock
  section).
- **Shared clock races**: ov8858's probe calls `devm_v4l2_sensor_clk_get()`, which sets
  19.2 MHz and then 24 MHz; both fail with -EBUSY if the IMX241 has the clock prepared at
  that moment (probe failure or a 19.2 MHz rear camera). imx241 keeps it prepared only
  while streaming (plus 1 s autosuspend), so this needs an ov8858 rebind during front
  streaming. Making 0003 skip the 19.2 MHz step would remove the first failure mode.
- **Concurrent streaming** of both cameras works only at a common rate (24 MHz in practice).
- **GPIO4 regulator**: see the open item above. Sensor delays for libcamera are unknown
  (defaults).
- **ov8858 / imx241 probe order at boot** is handled by the modprobe.d softdeps (clock,
  regulator and GPIO cells first); without them a missing clock provider would make the
  driver fall back to a fake fixed clock, as with ov8858.
