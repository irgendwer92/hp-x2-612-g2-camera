# HP Pro x2 612 G2 camera on Linux

Out-of-tree kernel patches to bring up the **rear 8 MP camera (OmniVision OV8858)**
of the HP Pro x2 612 G2 tablet on its Intel IPU3, for use through libcamera.

> **Status: working.** With these patches on Linux 7.2.9 the rear camera probes
> ("Detected OV8858 sensor, revision 0xb2"), libcamera lists it as
> "Internal back camera", and it streams in `cam` and `qcam`. Image quality is
> uncalibrated with stock libcamera; see Risks.

The front camera (ACPI `INT347F`, Sony IMX241) has a new driver (`0006`). It
streams in a test boot at 2592x1944 and 1296x972, and shows a live image in
qcam with the patched libcamera; orientation is correct (unmirrored). See
[`docs/front-camera.md`](docs/front-camera.md).

## Why it doesn't work upstream

The IPU3 camera on this tablet needs three things that mainline Linux is missing:

1. **PMIC board data.** The sensors are powered by a TPS68470 PMIC
   (`INT3472:05`, Intel "CRD-G" reference design). The kernel only knows how
   that PMIC is wired on a few machines, so on this one it bails out with
   `No board-data found for this model`. Without power, the sensors are never
   enumerated.
2. **ipu-bridge.** The sensor HID `INT3477` is not in ipu-bridge's table, so no
   CSI-2 graph is built for it.
3. **ov8858.** The driver only matches through device tree (Rockchip).

| Patch | Change |
|---|---|
| `0001` | int3472/tps68470: HP Pro x2 612 G2 regulator, GPIO and DMI board data |
| `0002` | ipu-bridge: add OV8858 (`INT3477`, 360 MHz link) |
| `0003` | ov8858: ACPI match, defer until the fwnode graph exists, request 24 MHz xvclk |
| `0004` | int3472/tps68470: front camera (IMX241) supplies and GPIOs |
| `0006` | new `imx241` sensor driver (front camera), streams at 2592x1944 and 1296x972 |
| `0005` | ipu-bridge: add IMX241 (`INT347F`, 498 MHz link) |

The hardware facts behind these patches, read from ACPI at runtime, are in
[`docs/hardware.md`](docs/hardware.md).

## Usage

Requirements: `base-devel`, `linux-headers` matching the running kernel, and
network access for the first fetch. To use the camera you also need
`libcamera`, `libcamera-tools` and optionally `pipewire-libcamera`.

### Try it without installing

```sh
make                        # fetch upstream sources for `uname -r`, apply patches, build
sudo scripts/test-load.sh   # swap in the patched modules and print a diagnostic report
sudo scripts/restore.sh     # go back to the in-tree modules
```

Stop anything using the camera stack first (for example,
`systemctl --user stop wireplumber pipewire`). Rebooting also undoes the test.

### Install permanently (Arch, DKMS)

```sh
cd packaging/arch && makepkg -si
```

The modules go to `/updates/dkms`, which takes priority over the in-tree ones.
A `modprobe.d` softdep makes sure the TPS68470 clock, regulator and GPIO drivers
load before the sensor. Otherwise the sensor silently ends up with a fake
19.2 MHz clock.

The package vendors sources for one kernel series (e.g. 7.2.x). After moving to
a new series, rebuild the package; until you do, DKMS skips the build and the
stock modules stay in use.

### Other kernel versions

`scripts/prepare.sh <kernelrelease>` maps a release string to an upstream tag
(`7.2.9-arch1-1` → `v7.2.9`), fetches only the 5 affected files and applies
`patches/*.patch`. If a patch doesn't apply cleanly, the build fails instead of
going ahead with a half-patched tree.

## Risks

- **Rail mapping.** The BIOS leaves the PMIC hint fields empty. The rails in
  `0001` (CORE 1.2 V → DVDD, ANA 2.8 V → AVDD, VSIO 1.8 V → DOVDD, VCM 2.8 V
  always on) and the reset/enable lines (`s_resetn`/`s_enable`) match what the
  Windows driver programs for this board, recovered by static analysis in
  [`docs/windows-ctrllogic-re.md`](docs/windows-ctrllogic-re.md).
- **The VCM rail must be on** for the sensor to answer on I2C, so `0001` keeps
  it always on. That costs a little idle power.
- **Testing with `scripts/test-load.sh` only works once per boot.** The PMIC
  driver consumes its ACPI dependency list on the first successful probe.
- **Colour order and orientation** are confirmed correct on this module.
- **Image quality** with stock libcamera is uncalibrated (strong lens shading).
  `libcamera/patches/` adds IPU3 lens shading correction and the correct OV8858
  black level, and `tools/lsc/` calibrates the tables; both are verified on
  this tablet but only used by a locally built libcamera so far.

## Upstreaming

The patches are in `git format-patch` style but carry
`Signed-off-by: TODO <TODO>` placeholders. They should go upstream only after
they have been confirmed on real hardware.

## License

GPL-2.0, the same as the kernel sources these patches modify.
