# HP Pro x2 612 G2 cameras on Linux

Kernel patches, a DKMS package and a patched libcamera that make both cameras
of the HP Pro x2 612 G2 tablet work on Linux (Intel IPU3):

- **Rear, 8 MP OmniVision OV8858** with autofocus: works with the patched
  kernel modules. With the patched libcamera it also gets the correct black
  level and, if you calibrate your tablet, lens shading correction.
- **Front, 5 MP Sony IMX241**: works with a new `imx241` driver
  (2592x1944 and 1296x972 at 30 fps) and the patched libcamera. See
  [`docs/front-camera.md`](docs/front-camera.md).

Tested on Arch Linux with kernel 7.2.9 and libcamera 0.7.2. With both parts
installed, PipeWire offers "Internal back camera" and "Internal front camera"
to applications.

This is for the **HP Pro x2 612 G2** only. The PMIC board data is matched by
DMI, but the ipu-bridge and ov8858 changes would also affect other machines
with the same sensor IDs; installing the packages anywhere else is untested.

## Contents

- [Installation](#installation)
- [Applications](#applications)
- [Updates](#updates)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)
- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [Development and bring-up tools](#development-and-bring-up-tools)
- [Known limitations](#known-limitations)
- [Upstreaming](#upstreaming)
- [License](#license)

## Installation

There are two parts. Both are needed for two cameras; the first alone gives
you the rear camera.

1. **Kernel modules** (`packaging/arch`, DKMS): patched PMIC, ipu-bridge and
   ov8858 drivers plus the new imx241 driver.
2. **libcamera** (`packaging/libcamera`): Arch's libcamera rebuilt with the
   patches from `libcamera/patches/`. Stock libcamera only shows the rear
   camera, without lens shading correction and with the wrong black level.

Everything is built locally from this repository; nothing is downloaded from
third parties except the upstream kernel sources (git.kernel.org), libcamera
(git.libcamera.org) and Arch's libcamera packaging (gitlab.archlinux.org).

### Prerequisites

```sh
sudo pacman -S --needed base-devel git curl dkms linux-headers
```

Install the headers package for every kernel you boot (`linux-lts-headers`
for `linux-lts`, and so on). DKMS compiles the modules for each of them.

```sh
git clone https://github.com/irgendwer92/hp-x2-612-g2-camera.git
cd hp-x2-612-g2-camera
```

All commands below run from the repository root, as your normal user
(`makepkg` asks for sudo when it installs).

### 1. Kernel modules (DKMS)

```sh
(cd packaging/arch && makepkg -si)
```

This fetches five upstream driver files for your running kernel's version,
applies `patches/*.patch` and installs the result as the DKMS package
`hp-x2-612-g2-camera-dkms`. DKMS then builds the modules into
`/lib/modules/<kernel>/updates/dkms`, which takes priority over the in-tree
modules. A `modprobe.d` file makes sure the TPS68470 clock, regulator and GPIO
drivers load before the sensor drivers.

**Reboot.** The PMIC driver can only set up the cameras once per boot, so
the new modules take effect after a reboot. Then check:

```sh
modinfo -n ov8858 imx241               # both under .../updates/dkms/
journalctl -k -b | grep -E 'ov8858|imx241|ipu3-cio2'
```

You should see `Detected OV8858 sensor`, `Sony IMX241 rev 0x00, 24000000 Hz
clock, ...` and `Connected 2 cameras`.

### 2. Patched libcamera

```sh
packaging/libcamera/update.sh
sudo install -Dm644 packaging/libcamera/hp-x2-libcamera.hook /etc/pacman.d/hooks/hp-x2-libcamera.hook
```

`update.sh` clones Arch's libcamera packaging, builds the same version with
the patches applied (`pkgrel` + `.1`, for example `0.7.2-4.1`) and installs
`libcamera`, `libcamera-ipa` and `libcamera-tools` in place of the stock
packages. The build takes a while on the tablet.

The pacman hook is optional but recommended: Arch updates to libcamera still
install normally (there is no `IgnorePkg`), and when one replaces the patched
build, the hook prints a reminder to run `update.sh` again.

Then restart PipeWire (or log out and in) and check:

```sh
systemctl --user restart pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
pacman -Qi libcamera | grep 'HP Pro x2'       # the patched build is installed
cam -l                                         # two cameras: ...LNK0 (rear) and ...LNK1 (front)
```

For PipeWire applications you also need `pipewire-libcamera`
(`sudo pacman -S pipewire-libcamera`).

### 3. Optional: lens shading calibration (rear camera)

The rear lens vignettes strongly and has a colour cast (magenta centre, cyan
corners). The patched libcamera can correct that, but the tables are **per
device**: they come from flat-field shots of *your* tablet. Without them the
package installs an identity table (no correction); everything else works.

To calibrate, follow [`tools/lsc/README.md`](tools/lsc/README.md): capture a
few frames of an evenly lit sheet of paper, run `calibrate.py`, which writes
`lsc-out/ov8858.yaml`, and run `packaging/libcamera/update.sh` again to
package it. `lsc-out/` is not part of the repository; tables measured on
another tablet are only an approximation for yours.

## Applications

- **Through PipeWire** (the usual way; needs `pipewire-libcamera`): browsers
  and apps that use the camera portal see both cameras.
- **Electron and Chromium apps** (Signal Desktop, Chromium, ...) only use
  PipeWire cameras with `--enable-features=WebRtcPipeWireCamera`, for example
  `chromium --enable-features=WebRtcPipeWireCamera`. In Chromium you can also
  enable `chrome://flags/#enable-webrtc-pipewire-camera`.
- **Firefox**: if the cameras do not show up, set
  `media.webrtc.camera.allow-pipewire` to `true` in `about:config`.
- **libcamera tools**: `qcam` (GUI) and `cam` (command line, from
  `libcamera-tools`). They need exclusive access, so stop PipeWire first:
  `systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber`.

Applications that open `/dev/video*` directly (plain V4L2) do not work as is:
on IPU3 the raw sensor output needs libcamera's image processing. Try
starting them through libcamera's compatibility wrapper, `libcamerify <app>`.

## Updates

- **Kernel updates within the same series** (for example 7.2.9 → 7.2.10):
  DKMS rebuilds the modules automatically. Reboot as usual.
- **A new kernel series** (for example 7.2 → 7.3): the package vendors the
  driver sources of one series, and DKMS skips other series on purpose (the
  stock modules are used, so the cameras are gone but nothing breaks). Rebuild
  the package while running the new kernel:
  `git pull && (cd packaging/arch && makepkg -si)`, then reboot. If a patch
  does not apply to the new kernel, the build stops with a message.
- **libcamera updates from Arch**: run `packaging/libcamera/update.sh` again
  when the pacman hook reminds you. Until then the rear camera keeps working
  with stock libcamera; the front camera and the image fixes are gone. If a
  patch stops applying to a new libcamera version, `update.sh` stops with a
  message and the series in `libcamera/patches/` needs a rebase.

## Troubleshooting

Most problems show up in the kernel log:

```sh
journalctl -k -b | grep -iE 'int3472|tps68470|ov8858|imx241|ipu3-cio2|ipu_bridge'
```

| Symptom | Likely cause and fix |
|---|---|
| `No board-data found for this model` | The stock PMIC module is loaded. Check `dkms status` and `modinfo -n intel_skl_int3472_tps68470` (must be under `updates/dkms`). Missing headers for this kernel, a different kernel series (see [Updates](#updates)) or no reboot yet. |
| `dkms status` shows nothing for the running kernel | Install the matching headers package, then `sudo dkms autoinstall` and reboot. |
| No camera at all, `cam -l` empty | `ipu3-cio2` only registers its media device after *both* sensors bound. Look for `ov8858` or `imx241` errors in the log. |
| Only the rear camera | Stock libcamera is installed (`pacman -Qi libcamera` does not mention "HP Pro x2 612 G2 patches"); run `packaging/libcamera/update.sh`. |
| `cam`/`qcam`: camera busy or in use | PipeWire holds the camera; stop it (see [Applications](#applications)). |
| Electron/Chromium app shows no camera | Start it with `--enable-features=WebRtcPipeWireCamera` and install `pipewire-libcamera`. |
| Rear image has dark, cyan corners and a magenta centre | No lens shading calibration; see step 3. |
| Front image dark or noisy in dim light | The IMX241 is not very sensitive; the AGC already uses up to 8x analogue and 4x digital gain at 30 fps. More light helps. |
| `Algorithm 'Lsc' not found` | A tuning file with lens shading is used by stock libcamera. Remove any `/etc/libcamera/ipa/ipu3/ov8858.yaml` you copied there, or reinstall the patched libcamera. |
| Modules fail to load with a signature error | Your kernel enforces module signatures (Secure Boot setups); sign the DKMS modules or relax the policy. |
| Cameras gone after a crash or a failed experiment | Shut down completely and power on again; a reboot does not reset the PMIC. |

If you report a problem, include the filtered kernel log, `dkms status`,
`uname -r`, `pacman -Q libcamera` and `cam -l`.

## Uninstalling

```sh
sudo pacman -R hp-x2-612-g2-camera-dkms             # kernel modules and modprobe.d file
sudo pacman -S libcamera libcamera-ipa libcamera-tools   # back to Arch's libcamera (pacman warns about the downgrade from -N.1)
sudo rm -f /etc/pacman.d/hooks/hp-x2-libcamera.hook
```

Reboot afterwards. The stock modules are then used again and the cameras are
unavailable, as before. The build cache in the repository can be removed with
`make distclean` and by deleting `packaging/libcamera/{arch-upstream,src,pkg,libcamera}`
and the `*.pkg.tar.*` files.

## How it works

Mainline Linux is missing four things for these cameras:

1. **PMIC board data.** The sensors are powered by a TPS68470 PMIC
   (`INT3472:05`, Intel "CRD-G" reference design). The kernel only knows how
   that PMIC is wired on a few machines, so on this one it fails with
   `No board-data found for this model`. Without power, the sensors are never
   enumerated.
2. **ipu-bridge.** The sensor HIDs `INT3477` (rear) and `INT347F` (front) are
   not in ipu-bridge's table, so no CSI-2 graph is built for them.
3. **ov8858.** The driver only matches through device tree (Rockchip).
4. **imx241.** There is no driver for the front sensor.

### Kernel patches (`patches/`)

| Patch | Change |
|---|---|
| `0001` | int3472/tps68470: HP Pro x2 612 G2 board data: regulators, GPIOs and DMI match (rear camera) |
| `0002` | ipu-bridge: add OV8858 (`INT3477`, 360 MHz link) |
| `0003` | ov8858: ACPI match, defer until the fwnode graph exists, request a 24 MHz xvclk |
| `0004` | int3472/tps68470: front camera (IMX241) supplies and GPIOs |
| `0005` | new `imx241` sensor driver (front camera), 2592x1944 and 1296x972 at 30 fps |
| `0006` | ipu-bridge: add IMX241 (`INT347F`, 498 MHz link) |

### libcamera patches (`libcamera/patches/`, against libcamera 0.7.2)

| Patch | Change |
|---|---|
| `0001` | ipa: ipu3: lens shading correction (new `Lsc` algorithm) |
| `0002` | ipa: ipu3: OV8858 tuning file (identity shading table, replaced by your calibration) |
| `0003` | libipa: camera sensor helper: OV8858 black level (16 at 10 bit) |
| `0004` | ipa: ipu3: BlackLevelCorrection uses the sensor helper's black level instead of a fixed 64 |
| `0005` | libipa: camera sensor helper for the IMX241 (gain model, black level 64) |
| `0006` | camera sensor properties for the IMX241 (pixel size, test patterns) |
| `0007` | ipa: ipu3: AGC also uses the sensor digital gain (up to 4x, frame rate unchanged) |
| `0008` | ipa: ipu3: IMX241 tuning file (brighter AGC target) |

Details on the libcamera side, including how to build and test it from a
source tree, are in [`libcamera/README.md`](libcamera/README.md).

### Documentation

- [`docs/hardware.md`](docs/hardware.md): ACPI facts, the current interface
  between the patches, and the chronological bring-up log.
- [`docs/front-camera.md`](docs/front-camera.md): the IMX241 driver: modes,
  clocks, power sequence, open items.
- [`docs/windows-ctrllogic-re.md`](docs/windows-ctrllogic-re.md) and
  [`docs/imx241-windows-re.md`](docs/imx241-windows-re.md): how the power
  sequences and register settings were recovered from the Windows drivers
  (static analysis only).
- [`tools/lsc/README.md`](tools/lsc/README.md): lens shading calibration.

## Repository layout

| Path | What |
|---|---|
| `patches/` | kernel patches (applied to pristine upstream files at build time) |
| `src/` | the patched kernel files, for reading and diffing |
| `upstream/` | pristine copies (v7.2.9) of the upstream files the patches apply to |
| `packaging/arch/` | DKMS package (`PKGBUILD`) |
| `packaging/libcamera/` | patched libcamera package: `update.sh`, `PKGBUILD`, pacman hook |
| `packaging/modprobe.d/` | load-order softdeps, installed by the DKMS package |
| `libcamera/` | libcamera patches and notes |
| `tools/lsc/` | lens shading calibration |
| `tools/raw2png.py` | preview of raw IPU3 captures |
| `Makefile`, `Kbuild`, `dkms.conf` | out-of-tree build and DKMS configuration |
| `scripts/`, `debug/` | build helpers and developer tools (see below) |
| `docs/` | hardware notes and reverse-engineering notes |

## Development and bring-up tools

None of these are needed for a normal installation.

**Build without packaging.** `make` fetches the upstream sources for the
running kernel (`make KVER=<release>` for another one), applies
`patches/*.patch` (`scripts/prepare.sh`, which maps e.g. `7.2.9-arch1-1` to
the tag `v7.2.9`) and builds the four modules into the repository root. A
patch that does not apply stops the build. `make dist` writes the vendored
DKMS tree and a tarball to `build/dist/`; `make clean` and `make distclean`
clean up.

**Try the modules without installing** (only on a system *without* the DKMS
package, once per boot, as the PMIC can only probe once):

```sh
make
systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
sudo scripts/test-load.sh     # swap in the built modules, print a diagnostic report
sudo scripts/restore.sh       # back to the in-tree modules (or reboot)
```

**Bring-up tools.** These were used to get the sensors working and are kept
for reference and for debugging new boards or driver changes. Each script's
header explains its use and safety notes.

| Tool | Purpose |
|---|---|
| `scripts/front-test.sh`, `scripts/front-test-restore.sh` | raw front-camera capture with `v4l2-ctl`, and one-off test boots with separately built modules |
| `scripts/pmic-dump.sh` | read-only, decoded dump of the TPS68470 registers (needs i2c-tools) |
| `scripts/build-debug.sh`, `debug/0100-*.patch` | build ov8858 with diagnostic module parameters (historical) |
| `scripts/debug-probe.sh`, `scripts/debug-gpio-sweep.sh`, `scripts/debug-pin-sweep.sh` | experiments from before the OV8858 answered on I2C; drive PMIC GPIOs directly (historical) |
| `scripts/front-probe.sh`, `debug/front-probe/` | throw-away module that powered and identified the front sensor before the driver existed (historical) |
| `scripts/fetch-sources.sh` | fetch the pristine upstream files (used by `prepare.sh`) |

## Known limitations

- **Board-specific.** The board data, power sequences and tuning are for the
  HP Pro x2 612 G2 only. Lens shading tables are per device (see step 3).
- **Rail mapping.** The BIOS leaves the PMIC hint fields empty. The rails and
  GPIOs in `0001` and `0004` match what the Windows driver programs for this
  board, recovered by static analysis
  ([`docs/windows-ctrllogic-re.md`](docs/windows-ctrllogic-re.md)).
- **The VCM rail is always on**, because the OV8858 does not answer on I2C
  without it. That costs a little idle power.
- **Future libcamera releases** include the upstream IPU3 lens shading
  algorithm, which conflicts with our `0001`/`0002`. When Arch moves to such a
  release, `packaging/libcamera/update.sh` stops with a "does not apply"
  message until the series is rebased.
- **Vendored sources.** The DKMS package carries the driver sources of the
  kernel it was built on; stable updates to those drivers are not picked up
  until you rebuild the package. See the comment in `dkms.conf`.
- **Front camera:** low light sensitivity, no lens shading correction,
  hflip/vflip controls untested (the default orientation is correct and
  unmirrored); see
  [`docs/front-camera.md`](docs/front-camera.md#open-items-and-risks).

## Upstreaming

The kernel patches (`patches/`) and libcamera patches (`libcamera/patches/`)
are in `git format-patch` form and signed off, but have not been submitted
yet:

- `0001`, `0004`: platform/x86 (int3472 / TPS68470 board data)
- `0002`, `0003`, `0005`, `0006`: media (ipu-bridge, ov8858, new imx241 driver)
- libcamera: an IPU3 lens shading algorithm by Daniel Scally (patchwork
  27072) was merged upstream after 0.7.2. Our `0001`/`0002` should become
  fixes on top of it (grid placement relative to the BDS output, gains above
  5x for the OV8858 corners). The sensor helpers, IPU3 black level and
  digital gain changes and the tuning files are independent; `0007` needs a
  rebase onto upstream's newer libipa AGC.

## License

- The kernel patches (`patches/`), the patched files in `src/` and
  `upstream/`, and the new `imx241` driver are GPL-2.0, like the Linux kernel
  files they modify.
- The libcamera patches (`libcamera/patches/`) carry the licenses of the
  libcamera files they modify or add: LGPL-2.1-or-later for library and IPA
  code, CC0-1.0 for the tuning files. `packaging/libcamera/PKGBUILD` is
  derived from Arch Linux's libcamera PKGBUILD.
- Everything else (scripts, tools, packaging, documentation) is GPL-2.0, see
  [`LICENSE`](LICENSE).

No Intel, HP or other vendor binaries, firmware or tuning files are included.
The Windows drivers were only analysed to recover register values and power
sequences; nothing from them is redistributed.
