# libcamera: IPU3 lens shading correction and front camera support

Patches against libcamera **v0.7.2** for the HP Pro x2 612 G2. They add lens
shading correction (LSC) to the IPU3 IPA, use the correct sensor black level,
let the IPU3 AGC use the sensor digital gain, and add support for the IMX241
front camera. They are in `git format-patch` form, meant to go upstream.

| Patch | Change |
|---|---|
| `0001` | `ipa: ipu3: Add lens shading correction`: new `Lsc` algorithm (`src/ipa/ipu3/algorithms/lsc.{h,cpp}`) |
| `0002` | `ipa: ipu3: Add OV8858 tuning file`: `src/ipa/ipu3/data/ov8858.yaml` with a placeholder unity (all 1.0) shading table |
| `0003` | `ipa: libipa: camera_sensor_helper: Add OV8858 black level` (16 at 10 bits) |
| `0004` | `ipa: ipu3: blc: Use the sensor black level` from the sensor helper instead of a fixed 64 |
| `0005` | `ipa: libipa: camera_sensor_helper: Add IMX241`: gain model 256 / (256 - code), black level 64 |
| `0006` | `libcamera: camera_sensor_properties: Add IMX241`: 1.12 µm pixels (unverified, distributor listing), SMIA test patterns |
| `0007` | `ipa: ipu3: agc: Use the sensor digital gain` (`V4L2_CID_DIGITAL_GAIN`) up to 4x, at unchanged frame rate |
| `0008` | `ipa: ipu3: Add IMX241 tuning file`: AGC relative luminance target 0.32 |

## Install (packaged)

`packaging/libcamera/update.sh` builds Arch's current libcamera package with
these patches and installs it in place of the stock packages. If
`lsc-out/ov8858.yaml` exists (a calibration from [`tools/lsc/`](../tools/lsc/)),
it is packaged as the OV8858 tuning file. Otherwise the placeholder table from
`0002` is used, which leaves the shading uncorrected. See the top-level
[`README.md`](../README.md).

## Build from a source tree (development)

For development, apply the patches to a libcamera checkout and run it from
the build tree. The system libcamera is not touched.

```sh
git clone https://git.libcamera.org/libcamera/libcamera.git
cd libcamera
git checkout -b ipu3-lsc v0.7.2
git am /path/to/hp-x2-612-g2-camera/libcamera/patches/*.patch

python3 -m venv .venv
.venv/bin/pip install jinja2 ply pyyaml
source .venv/bin/activate

meson setup build -Dpipelines=ipu3 -Dipas=ipu3 -Dcam=enabled -Dqcam=enabled \
    -Dgstreamer=disabled -Dv4l2=false -Dpycamera=disabled \
    -Ddocumentation=disabled -Dtest=false -Dlc-compliance=disabled
ninja -C build
```

The build uses about 200 MB and takes about 15 minutes on 4 cores. It needs
the same development packages as the Arch `libcamera` package (gnutls,
libyaml, libevent, Qt6 for qcam, SDL2/libjpeg for cam).

## Run from the build tree

Use the `cam` and `qcam` binaries **from the build tree**. They are linked
with an RUNPATH to the build-tree `libcamera.so`. When libcamera runs from its
build tree it:

- loads IPA modules from `build/src/ipa/` instead of `/usr/lib/libcamera`;
- looks for tuning files in `src/ipa/<ipa>/data/` of the source tree, so
  `src/ipa/ipu3/data/ov8858.yaml` and `imx241.yaml` are picked up
  automatically (the file name is the sensor model plus `.yaml`).

```sh
# In the libcamera checkout. Stop anything holding the camera first, e.g.:
#   systemctl --user stop wireplumber pipewire
./build/src/apps/qcam/qcam
./build/src/apps/cam/cam -c1 --capture=10 --file=/tmp/frame-#.ppm   # or .dng for raw
```

To use another tuning file (for example the output of the calibration tool):

```sh
LIBCAMERA_IPU3_TUNING_FILE=/path/to/ov8858.yaml ./build/src/apps/qcam/qcam
```

libcamera 0.7.2 checks these locations in order:

1. `LIBCAMERA_IPU3_TUNING_FILE`, the full path to one file. The name comes
   from the IPA module name `ipu3` in upper case.
2. `LIBCAMERA_IPA_CONFIG_PATH`, a colon-separated list of directories. Each
   directory is searched for `ipu3/ov8858.yaml`.
3. In the build tree: `src/ipa/ipu3/data/`. When installed: `/etc/libcamera/ipa`
   and `/usr/share/libcamera/ipa`.
4. `uncalibrated.yaml`, as a fallback, in the same places.

The log line `IPAProxy ... Using tuning file ...` shows which file was used.
For debug output from the algorithm, set
`LIBCAMERA_LOG_LEVELS=IPU3Lsc:0,IPAProxy:0`.

### IPA module signing

The build signs `ipa_ipu3.so` with a key generated at build time
(`build/src/ipa/ipu3/ipa_ipu3.so.sign`). The build-tree `libcamera.so` embeds
the public half of that key, so the build-tree `cam`/`qcam` load the IPA
in-process, without isolation. You can check this with
`LIBCAMERA_LOG_LEVELS=IPAManager:0`, which prints
`IPA module .../ipa_ipu3.so signature is valid`.

Do not mix the two trees. The system `cam` with
`LIBCAMERA_IPA_MODULE_PATH=build/src/ipa` fails the signature check because
the keys differ. libcamera then isolates the IPA, and the system
`ipu3_ipa_proxy` worker loads an IPA built against a different tree. To test
isolated mode on purpose, run the build-tree binaries with
`LIBCAMERA_IPA_FORCE_ISOLATION=1`. The build-tree proxy worker
(`build/src/libcamera/proxy/worker/ipu3_ipa_proxy`) is then used
automatically.

### A/B comparison

The algorithm supports the `LensShadingCorrectionEnable` control (default
on). It is reported in the frame metadata (`cam --metadata`) and can be
turned off from a `cam` capture script:

```yaml
# lsc-off.yaml
frames:
  - 0:
      LensShadingCorrectionEnable: false
```

```sh
./build/src/apps/cam/cam -c1 --capture=5 --script=lsc-off.yaml --file=/tmp/off-#.ppm
```

The other way is to remove the `- Lsc:` block from the tuning file. Without
it the shading block is left at the kernel defaults, as in unpatched 0.7.2.

## Tuning format

```yaml
- Lsc:
    grid: [ 33, 25 ]          # sample points: [ columns, rows ]
    sets:
      - ct: 5000              # colour temperature in K
        r:  [ ... ]           # columns*rows gains, row-major
        gr: [ ... ]
        gb: [ ... ]
        b:  [ ... ]
      - ct: 3000              # optional further sets
        ...
```

- **Grid geometry.** The samples cover the **full sensor pixel array**
  (`activeAreaSize`, 3264x2448 for the OV8858), edges included, with uniform
  spacing. Sample `i` of `N` lies at pixel `x = i * (W - 1) / (N - 1)`, so the
  first and last samples fall on the centres of the first and last pixels.
  Rows work the same way. Any grid of 2x2 or more is accepted.
- **Channels** are named after the colour of the pixel they correct, not
  after their position in the Bayer pattern. For the OV8858 (BGGR), the raw
  2x2 cell is `B Gb / Gr R`: `gr` is the green on the red rows and `gb` the
  green on the blue rows. The kernel shifts the input by one line so that the
  ImgU always processes GRBG, so channel names, not positions, are what the
  hardware sees.
- **Gains** are multipliers and must be finite and > 0. Values below 1.0 are
  clamped to 1.0 because the hardware cannot attenuate, and a warning is
  logged. Normalise each table so that its minimum, usually at the optical
  centre, is 1.0. Leave the overall white balance to AWB. Gains up to 5.0 use
  full precision. Above that the gain factor is raised automatically (range
  up to 9.0 at half precision, then 17.0 at quarter precision). Larger values
  are clamped.
- **Several sets** are interpolated linearly by the AWB colour temperature,
  quantised to 10 K. Outside the covered range the nearest set is used. With
  a single set it is always used. Until AWB has produced an estimate, 5000 K
  is assumed.
- **Missing block.** If there is no `Lsc` entry, the IPA does not touch the
  shading block (kernel defaults, unity gains).

The black level is not part of the tuning file: patch `0004` takes it from
the camera sensor helper (16 for the OV8858, 64 for the IMX241, 64 for
sensors whose helper has none).

## How it maps to the hardware

- The ImgU SHD block works on the **BDS output** frame. The kernel sizes its
  shading DMA operations from the BDS rectangle (`imgu_css_shd_ops_calc()` is
  called with `rect[IPU3_CSS_RECT_BDS].height`).
- Grid nodes are `2^block_width_log2` by `2^block_height_log2` BDS pixels
  apart, starting at BDS pixel (0, 0) (`x_start = y_start = 0`). The
  algorithm uses at most 73 nodes per row (the kernel default; the UAPI allows
  up to 128). The LUT holds 28 sets of 146 cells, and each set holds
  `floor(146 / width)` whole rows, so there are at most
  `28 * floor(146 / width)` rows. The algorithm picks the smallest block size
  that fits. A full 3264x2448 BDS output gives 52x40 nodes of 64x64 pixels.
- Each node is mapped back to the pixel array as follows: BDS scale
  (`iif / bds`), then the centred input-feeder crop
  (`((sensor_out - iif) / 2) & ~1`, as in the kernel `imgu_css_cfg_acc()`),
  then sensor binning or skipping (`analogCrop / outputSize`), then the
  analogue crop offset. The node is then sampled bilinearly from the tuning
  grid.
- LUT entry = `round((gain - 1) * 1024 >> gain_factor)`, clamped to
  [0, 4095]. A zero LUT means unity gain, which is also the kernel default.
- The configuration and LUT (about 34 KB) are written to every parameters
  buffer with `use.acc_shd = 1`.

## Status

All patches are tested on the HP Pro x2 612 G2 (see
[`docs/hardware.md`](../docs/hardware.md)):

- LSC with tables from `tools/lsc` and the black level at 16: on a flat field
  the corner R/G ratio goes from 0.62–0.66 to 1.02–1.03 and B/G from
  0.97–1.01 to 1.00–1.01. No grid offset, striping seam or wrong gain scaling is visible,
  so the inferred LUT encoding and grid origin hold in practice.
- BLC 16 gives correct blacks on the OV8858 (64 crushed the shadows).
- The IMX241 helper and properties let libcamera register the front camera;
  its analogue gain model was checked against raw captures.
- With the sensor digital gain, the IMX241 AGC keeps 30 fps in dim light; at
  the 0.32 target about 2.8x digital gain is expected in evening indoor light.

Remaining caveats:

- The LUT encoding is inferred, not documented. The calibrated tables reach
  gains of about 7.15, so gain factor 1 is in use and looks right; gain
  factor 2 (gains above 9.0) is untested.
- The IMX241 pixel size (1.12 µm) is from a distributor listing, not a Sony
  datasheet. The imx241 kernel driver is not upstream yet, which upstream
  libcamera will likely require before taking `0005`, `0006` and `0008`.
- `0007` assumes that the default value of `V4L2_CID_DIGITAL_GAIN` is unity
  gain. This holds for the IMX241 (SMIA, 0x100); the ov8858 driver's default
  is 0x200, whose meaning is not documented.

## Upstream

Upstream libcamera has since merged its own IPU3 LSC algorithm by Daniel
Scally ("ipa: ipu3: Add Lens Shading Correction algorithm", after v0.7.2,
built on the libipa `LscAlgorithm` and its tuning format). Patches `0001`
and `0002` are therefore for v0.7.2 only; for submission they need to be
reworked as fixes on top of the upstream algorithm (grid tied to the BDS
output, gain factor selection), and the tuning data converted to the libipa
format. `0003`–`0008` are independent of it, but `0007` needs a rebase onto
the upstream `AgcAlgorithm` port of the IPU3 AGC.
