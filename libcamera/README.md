# libcamera: IPU3 lens shading correction

Patches against libcamera **v0.7.2** that add lens shading correction (LSC)
to the IPU3 IPA, plus an OV8858 tuning file. They are meant to go upstream
eventually.

| Patch | Change |
|---|---|
| `0001` | `ipa: ipu3: Add lens shading correction`: new `Lsc` algorithm (`src/ipa/ipu3/algorithms/lsc.{h,cpp}`) |
| `0002` | `ipa: ipu3: Add OV8858 tuning file`: `src/ipa/ipu3/data/ov8858.yaml` with an identity (all 1.0) shading table |
| `0003` | `ipa: libipa: camera_sensor_helper: Add OV8858 black level` (16 at 10 bit) |
| `0004` | `ipa: ipu3: blc: Use the sensor black level` from the sensor helper |
| `0005` | `ipa: libipa: camera_sensor_helper: Add IMX241`: front camera gain model (256 / (256 - code)) and black level 64 |
| `0006` | `libcamera: camera_sensor_properties: Add IMX241`: 1.12 µm pixels, SMIA test patterns |

The system libcamera is not touched. Everything below builds and runs from a
local tree.

## Build

```sh
cd ~/Projects
git clone https://git.libcamera.org/libcamera/libcamera.git
cd libcamera
git checkout -b ipu3-lsc v0.7.2
git am ~/Projects/hp-x2-612-g2-camera/libcamera/patches/*.patch

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

## Run

Use the `cam` and `qcam` binaries **from the build tree**. They are linked
with an RUNPATH to the build-tree `libcamera.so`. When libcamera runs from its
build tree it:

- loads IPA modules from `build/src/ipa/` instead of `/usr/lib/libcamera`;
- looks for tuning files in `src/ipa/<ipa>/data/` of the source tree, so
  `src/ipa/ipu3/data/ov8858.yaml` is picked up automatically for the OV8858
  (the file name is the sensor model plus `.yaml`).

```sh
cd ~/Projects/libcamera
# Stop anything holding the camera first, for example:
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
`ipu3_ipa_proxy` worker loads an IPA built against a different tree. To test isolated
mode on purpose, run the build-tree binaries with
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
it the IPA behaves exactly as unpatched 0.7.2.

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

## How it maps to the hardware

- The ImgU SHD block works on the **BDS output** frame. The kernel sizes its
  shading DMA operations from the BDS rectangle (`imgu_css_shd_ops_calc()` is
  called with `rect[IPU3_CSS_RECT_BDS].height`).
- Grid nodes are `2^block_width_log2` by `2^block_height_log2` BDS pixels
  apart, starting at BDS pixel (0, 0) (`x_start = y_start = 0`). There are at
  most 73 nodes per row. The LUT holds 28 sets of 146 cells, and each set
  holds `floor(146 / width)` whole rows, so there are at most
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

## Status and open risks

Built, and the resampling/encoding was checked offline with a test harness
(not committed). It has **not been tested on hardware yet**.

- The gain encoding (UQ2.10 added to 1.0, 12 bits) is inferred. Evidence:
  the uAPI comment "gain factor [1, 5]"; the kernel default of an all-zero LUT
  with `shd_enable = 1`, which gives a normal image; and an upstream IPU3 LSC
  patch by Daniel Scally (2026, see below) that found "values in the LUT cease
  taking effect at 4096".
  First hardware test: put a constant gain of 2.0 in all tables. The image
  should get exactly one stop brighter before AGC reacts, or lock AE to see
  it.
- Grid origin and node or cell semantics are inferred. The model is that
  nodes sit on BDS pixels `i << log2`, starting at the top-left pixel. A wrong
  origin would show up as an off-centre correction. Test with a radial table
  and a flat field.
- Striping. For wide outputs the ImgU processes the frame in two vertical
  stripes. The kernel does not adjust `x_start` per stripe, and we assume the
  firmware does it. Look for a seam in the middle of the image.
- Channel naming. This relies on the kernel's realignment of the input to
  GRBG. If R and B correction look swapped, swap them in the calibration
  tool and report it.
- Upstream overlap. Daniel Scally (Ideas on Board) posted
  "ipa: ipu3: Add Lens Shading Correction algorithm" as part of an IPU3 libipa
  rework (v2, 2026-06-26, patchwork 27072). It builds on libipa classes that
  are not in 0.7.2 (`LscAlgorithm`, polynomial/table loaders, shared AWB/CCM
  contexts) and uses a grid tied to the sensor active area with `x_start`
  offsets. Before submitting this, rebase onto that series or coordinate on
  the libcamera-devel list. Its tuning format follows the libipa
  conventions, not the one documented here.
