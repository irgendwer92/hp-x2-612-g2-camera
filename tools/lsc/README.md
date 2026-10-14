# Lens-shading calibration (OV8858 on IPU3)

This tool measures the lens shading of the rear OV8858 camera (vignetting plus
the magenta-centre/cyan-corner colour cast) from flat-field raw captures. It
writes the `Lsc` tuning block that the IPU3 `Lsc` algorithm in libcamera reads:

```yaml
  - Lsc:
      grid: [33, 25]       # points across the full 3264x2448 array, edges included
      sets:
        - ct: 5000
          r:  [ 825 gains, row-major ]   # gain = max / response, >= 1.0
          gr: [ ... ]
          gb: [ ... ]
          b:  [ ... ]
```

Each of the four Bayer channels gets its own table, so the tables correct
colour shading as well as vignetting.

| File | Purpose |
|---|---|
| `capture.sh` | Captures raw SBGGR10_IPU3 frames with `cam` |
| `calibrate.py` | Unpacks the frames, averages them, subtracts black, smooths, computes gains, writes the YAML and heatmaps |
| `test_unpack.py` | Unit tests for the IPU3 10-bit unpacker (kernel byte layout, round trip, comparison with libcamera's own decoder) |
| `test_synthetic.py` | End-to-end test on synthetic packed cos⁴ flat fields with known shading |

## Raw format

libcamera v0.7.2 maps the IPU3 `Raw` stream role to the CIO2 output at full
sensor resolution:

- **Size:** 3264x2448.
- **Pixel format:** `SBGGR10_IPU3` (V4L2 `ip3b`, `V4L2_PIX_FMT_IPU3_SBGGR10`).
- **Packing:** 25 pixels in 32 bytes, little-endian. Pixel *i* of a block
  uses bits 10·i to 10·i+9, and the top 6 bits of byte 31 are padding.
- **Line stride:** `DIV_ROUND_UP(width, 50) * 64` = 4224 bytes, as set by
  `cio2_bytesperline()` in the kernel. A frame is therefore 10,340,352 bytes.

The IPU3 pipeline rejects a configuration that has only a raw stream.
`capture.sh` therefore requests a viewfinder stream as well and throws those
frames away.

## Requirements

`libcamera-tools` (for `/usr/bin/cam`), python3, and numpy. The system Python
does not have numpy, so the tool uses a venv:

```sh
cd tools/lsc
python3 -m venv .venv
.venv/bin/pip install numpy          # optional: pyyaml matplotlib
.venv/bin/python test_unpack.py      # sanity check
.venv/bin/python test_synthetic.py   # end-to-end check without hardware (~1 min)
```

matplotlib is optional. Without it, the heatmaps are written as plain PNGs
using only the standard library.

## Steps

All commands run from the repo root.

1. **Set up the target.** Use a matte white sheet that fills the *whole*
   frame. A sheet of paper or opal diffuser held right in front of the lens
   also works. It needs to be lit evenly: no shadows, no reflections, no
   flicker (daylight from a window, or a high-CRI LED panel). Defocus it a
   little, or hold it close, so no texture shows. Write down the colour
   temperature of the light, for example about 5000 K for overcast daylight.

2. **Stop PipeWire.** `cam` needs exclusive access to the camera.
   ```sh
   systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
   ```

3. **Capture the flat field.** The script keeps 8 raw frames after dropping
   24 frames while AE, AWB and AF settle. It also records `cam -I` output and
   per-frame metadata (ExposureTime, AnalogueGain, ColourTemperature) in
   `cam.log` and `metadata.txt`.
   ```sh
   tools/lsc/capture.sh -o captures/d50
   ```
   Check that it reports frames of 10340352 bytes and that the log contains
   `1: 3264x2448-SBGGR10_IPU3`.

4. **Optional but recommended: capture dark frames** to measure the real
   black level. Cover the lens completely.
   ```sh
   tools/lsc/capture.sh --dark -o captures/dark
   ```

5. **Optional: capture more illuminants.** Repeat step 3 under other lights,
   for example incandescent at about 2856 K, into `captures/a`.

6. **Restart PipeWire.**
   ```sh
   systemctl --user start pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
   ```

7. **Calibrate.**
   ```sh
   tools/lsc/.venv/bin/python tools/lsc/calibrate.py --ct 5000 captures/d50 \
       --dark captures/dark -o lsc-out
   # several illuminants:
   tools/lsc/.venv/bin/python tools/lsc/calibrate.py \
       --set 5000=captures/d50 --set 2856=captures/a --dark captures/dark -o lsc-out
   ```
   This writes the following to `lsc-out/`:
   - `lsc.yaml`: the `- Lsc:` block only.
   - `ov8858.yaml`: a complete tuning file. It contains `version: 1` and the
     algorithms Af, Agc, Awb, BlackLevelCorrection, ToneMapping and Lsc,
     mirroring `/usr/share/libcamera/ipa/ipu3/uncalibrated.yaml`.
   - `heatmap-<ct>-<ch>.png` and `gains-<ct>-<ch>.txt`.

   It also prints the corner/centre ratio and the maximum gain for each
   channel, plus the R/G and B/G colour shading at the corners. Take any
   clipping, brightness-drift or low-signal warnings seriously.

   Useful options:
   - `--black-level N`: used when `--dark` is not given. The default is 64.
   - `--max-gain 4.0`: caps the gains. Use 0 for no cap.
   - `--bayer-order BGGR`
   - `--block 32`: block-median tile size in colour-plane pixels.
   - `--stride`, `--width`, `--height`

8. **Install the tuning file. This needs the patched libcamera with the IPU3
   `Lsc` algorithm.** Stock libcamera 0.7.2 does not know `Lsc`. With this
   file installed, its IPA fails with `Algorithm 'Lsc' not found`, and the
   camera stops working in every application.

   Try the file for one session first:
   ```sh
   LIBCAMERA_IPU3_TUNING_FILE=$PWD/lsc-out/ov8858.yaml qcam
   ```
   Then install it system-wide. `/etc` is searched before `/usr/share`:
   ```sh
   sudo install -Dm644 lsc-out/ov8858.yaml /etc/libcamera/ipa/ipu3/ov8858.yaml
   systemctl --user restart pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
   ```
   To undo it, run `sudo rm /etc/libcamera/ipa/ipu3/ov8858.yaml`. libcamera
   then falls back to `uncalibrated.yaml`. The log line
   `Using tuning file ...` (`LIBCAMERA_LOG_LEVELS=IPAProxy:0`) shows which
   file is loaded.

## Black level

- The ov8858 kernel driver programs a sensor BLC target of 0x4005 = 0x10.
- libcamera 0.7.2's ov8858 `CameraSensorHelper` defines no black level, and
  neither does the rkisp1 `ov8858.yaml`.
- The IPU3 `BlackLevelCorrection` algorithm hard-codes 64 for all channels
  (`obgrid_param` in `src/ipa/ipu3/algorithms/blc.cpp`).

The default is therefore **64 at 10 bit**. That matches what the ImgU
subtracts before shading correction, so the gains fit the pipeline as it is
today. If dark frames (`--dark`) show a clearly different value, use the
measured one and fix `BlackLevelCorrection` to match. An error of 48 DN in
the black level skews the corner gains by roughly 48/(corner signal), which is
about 10 % at a corner level of 500 DN.

## Method

1. Unpack each frame and average the frames.
2. Subtract the black level for each channel.
3. Split the Bayer channels for the BGGR order (configurable). Gr is the green
   pixel on the red rows and Gb the green pixel on the blue rows.
4. Take the median of each 32x32 tile of each colour plane. This rejects dust,
   defects and noise.
5. Apply light 3x3 smoothing, using odd reflection at the borders so edge
   trends stay unbiased.
6. Sample at the 33x25 grid points with bilinear interpolation. Linear
   extrapolation covers the last half tile up to the array edges. Grid point
   *k* lies at full-array coordinate `k·(W−1)/32` (and `k·(H−1)/24` vertically).
   It is mapped into each colour plane using that plane's Bayer offset.
7. Compute `gain = max(smoothed response) / response`, then apply the
   optional cap.

## Test results (synthetic, no hardware)

`test_synthetic.py` generates 4 packed 3264x2448 frames with these
properties:
- cos⁴ falloff, with a different strength and optical centre for each
  channel (corner gains of R 3.7, G 2.5 and B 2.2)
- black level 64, Poisson shot noise and 2 DN read noise
- 2 dark frames

It then runs `calibrate.py` on them. The recovered gains match the analytic
ones as follows:

| Channel | Max error | Mean error |
|---|---|---|
| r | 0.66 % | 0.13 % |
| gr, gb, b | ≤ 0.31 % | ≤ 0.08 % |

The `--dark` path measures 64.00 on every channel. With `--max-gain 1.8`, no
gain exceeds 1.8 and the maximum error is 0.29 %. The YAML parses with PyYAML:
it has 4 × 825 row-major values, all of them ≥ 1.0, and the algorithms are in
the right order.
