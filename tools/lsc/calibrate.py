#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
Flat-field lens-shading calibration for the IPU3 + OV8858 rear camera of the
HP Pro x2 612 G2.

Input: raw frames written by `cam -F` from the IPU3 raw stream, i.e.
V4L2_PIX_FMT_IPU3_SBGGR10 / libcamera formats::SBGGR10_IPU3:
  * 10 bit per sample, every 25 pixels packed little-endian into 32 bytes
    (250 bits used, 6 most significant bits of byte 31 are padding),
  * line stride from the CIO2 driver: DIV_ROUND_UP(width, 50) * 64 bytes
    (4224 bytes for 3264 pixels); the stride is auto-detected from file size.

Output: the libcamera IPU3 `Lsc` tuning block
    - Lsc:
        grid: [33, 25]
        sets:
          - ct: 5000
            r:  [...]   # 33*25 gains, row-major, gain = max/response >= 1.0
            gr: [...]
            gb: [...]
            b:  [...]
plus a complete ov8858.yaml, per-channel heatmaps and a summary.
"""

import argparse
import glob
import math
import os
import struct
import sys
import zlib

import numpy as np

WIDTH = 3264
HEIGHT = 2448
BITS = 10
WHITE = (1 << BITS) - 1
GRID_W = 33
GRID_H = 25
CHANNELS = ("r", "gr", "gb", "b")

# --------------------------------------------------------------------------
# IPU3 10-bit packed format
# --------------------------------------------------------------------------
IPU3_PIXELS_PER_BLOCK = 25
IPU3_BYTES_PER_BLOCK = 32


def ipu3_min_stride(width):
    """Smallest possible line length in bytes (whole 25-pixel blocks)."""
    return -(-width // IPU3_PIXELS_PER_BLOCK) * IPU3_BYTES_PER_BLOCK


def cio2_stride(width):
    """Line length the ipu3-cio2 kernel driver uses (cio2_bytesperline())."""
    return -(-width // 50) * 64


def unpack_ipu3_10(buf, width, height, stride=None):
    """Unpack an IPU3-packed 10-bit Bayer buffer to a (height, width) uint16
    array.

    Pixel i of a 32-byte block occupies bits [10*i, 10*i + 10) of the block
    read as a little-endian 256-bit integer (kernel doc pixfmt-srggb10-ipu3).
    """
    data = np.frombuffer(buf, dtype=np.uint8)
    if stride is None:
        if data.size % height:
            raise ValueError(f"buffer size {data.size} is not a multiple of "
                             f"height {height}; pass --stride")
        stride = data.size // height
    nblocks = -(-width // IPU3_PIXELS_PER_BLOCK)
    if stride < nblocks * IPU3_BYTES_PER_BLOCK:
        raise ValueError(f"stride {stride} too small for width {width} "
                         f"(need >= {nblocks * IPU3_BYTES_PER_BLOCK})")
    if data.size < stride * height:
        raise ValueError(f"buffer too small: {data.size} < {stride * height}")

    lines = data[:stride * height].reshape(height, stride)
    blocks = lines[:, :nblocks * IPU3_BYTES_PER_BLOCK].reshape(
        height, nblocks, IPU3_BYTES_PER_BLOCK).astype(np.uint16)

    bit = np.arange(IPU3_PIXELS_PER_BLOCK) * BITS
    byte = bit // 8
    shift = (bit % 8).astype(np.uint16)
    lo = blocks[:, :, byte]
    hi = blocks[:, :, byte + 1]          # byte + 1 <= 31 for i = 24
    pix = ((lo | (hi << 8)) >> shift) & WHITE
    return pix.reshape(height, nblocks * IPU3_PIXELS_PER_BLOCK)[:, :width]


def pack_ipu3_10(img, stride=None):
    """Pack a (height, width) array of 10-bit values to IPU3 format.

    Implemented through a bit stream (np.packbits) so it is independent of
    the byte-gather logic in unpack_ipu3_10().
    """
    img = np.asarray(img, dtype=np.uint16)
    height, width = img.shape
    if np.any(img > WHITE):
        raise ValueError("values exceed 10 bits")
    nblocks = -(-width // IPU3_PIXELS_PER_BLOCK)
    if stride is None:
        stride = cio2_stride(width)
    padded = np.zeros((height, nblocks * IPU3_PIXELS_PER_BLOCK), np.uint16)
    padded[:, :width] = img
    padded = padded.reshape(height, nblocks, IPU3_PIXELS_PER_BLOCK)
    # LSB-first bits of each sample.
    bits = ((padded[..., None] >> np.arange(BITS, dtype=np.uint16)) & 1)
    bits = bits.astype(np.uint8).reshape(height, nblocks, 250)
    bits = np.concatenate(
        [bits, np.zeros((height, nblocks, 6), np.uint8)], axis=2)
    packed = np.packbits(bits, axis=2, bitorder="little")  # (h, nblocks, 32)
    out = np.zeros((height, stride), np.uint8)
    out[:, :nblocks * IPU3_BYTES_PER_BLOCK] = packed.reshape(height, -1)
    return out.tobytes()


# --------------------------------------------------------------------------
# Bayer helpers
# --------------------------------------------------------------------------
def bayer_offsets(order):
    """Map channel name -> (row, col) offset inside the 2x2 Bayer tile."""
    order = order.upper()
    if sorted(order) != sorted("RGGB"):
        raise ValueError(f"invalid Bayer order {order}")
    tile = [[order[0], order[1]], [order[2], order[3]]]
    out = {}
    for y in range(2):
        for x in range(2):
            c = tile[y][x]
            if c == "R":
                out["r"] = (y, x)
            elif c == "B":
                out["b"] = (y, x)
            else:
                # Green on the red row is Gr, on the blue row Gb.
                other = tile[y][1 - x]
                out["gr" if other == "R" else "gb"] = (y, x)
    return out


def split_planes(img, order):
    return {c: img[dy::2, dx::2] for c, (dy, dx) in bayer_offsets(order).items()}


# --------------------------------------------------------------------------
# Smoothing / sampling
# --------------------------------------------------------------------------
def block_median(plane, block):
    """Median of non-overlapping block x block tiles. The last row/column of
    tiles may be partial (they still get their own median). Returns the
    medians and the tile centre coordinates (plane pixel units)."""
    h, w = plane.shape
    ys = list(range(0, h, block))
    xs = list(range(0, w, block))
    med = np.empty((len(ys), len(xs)), np.float64)
    for i, y0 in enumerate(ys):
        rows = plane[y0:y0 + block]
        for j, x0 in enumerate(xs):
            med[i, j] = np.median(rows[:, x0:x0 + block])
    cy = np.array([(y0 + min(y0 + block, h) - 1) / 2 for y0 in ys])
    cx = np.array([(x0 + min(x0 + block, w) - 1) / 2 for x0 in xs])
    return med, cy, cx


def smooth3(a):
    """3x3 binomial smoothing with odd-reflection padding, which keeps linear
    trends at the borders unbiased (light denoise of the
    block-median surface)."""
    k = np.array([1.0, 2.0, 1.0]) / 4.0
    p = np.pad(a, 1, mode="reflect", reflect_type="odd")
    t = k[0] * p[:, :-2] + k[1] * p[:, 1:-1] + k[2] * p[:, 2:]
    return k[0] * t[:-2] + k[1] * t[1:-1] + k[2] * t[2:]


def _interp_axis(c, q):
    """Indices and fractions for (bi)linear interpolation of the sample
    positions q on the monotonic node coordinates c, with linear
    extrapolation beyond the outer nodes."""
    i = np.clip(np.searchsorted(c, q) - 1, 0, len(c) - 2)
    t = (q - c[i]) / (c[i + 1] - c[i])
    return i, t


def bilinear(surface, cy, cx, qy, qx):
    iy, ty = _interp_axis(cy, qy)
    ix, tx = _interp_axis(cx, qx)
    iy, ty = iy[:, None], ty[:, None]
    ix, tx = ix[None, :], tx[None, :]
    s00 = surface[iy, ix]
    s01 = surface[iy, ix + 1]
    s10 = surface[iy + 1, ix]
    s11 = surface[iy + 1, ix + 1]
    return ((1 - ty) * ((1 - tx) * s00 + tx * s01)
            + ty * ((1 - tx) * s10 + tx * s11))


def grid_positions(full_w, full_h, gw, gh):
    """Grid point positions in full-array pixel coordinates, uniform spacing,
    including both edges (0 and size - 1)."""
    return (np.linspace(0, full_h - 1, gh), np.linspace(0, full_w - 1, gw))


def plane_coords(gy, gx, offset):
    """Full-array coordinates -> coordinates in a half-resolution colour
    plane whose first sample sits at full-array position `offset`."""
    dy, dx = offset
    return (gy - dy) / 2.0, (gx - dx) / 2.0


# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
def _png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))


def write_png_rgb(path, rgb):
    """Minimal 8-bit RGB PNG writer (stdlib only)."""
    h, w, _ = rgb.shape
    raw = b"".join(b"\x00" + rgb[y].astype(np.uint8).tobytes()
                   for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2,
                                                0, 0, 0)))
        f.write(_png_chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(_png_chunk(b"IEND", b""))


def _colormap(t):
    """Small perceptual-ish ramp (dark blue -> teal -> yellow)."""
    stops = np.array([[0.0, 0x21, 0x0c, 0x4a],
                      [0.25, 0x3b, 0x52, 0x8b],
                      [0.5, 0x21, 0x91, 0x8c],
                      [0.75, 0x5e, 0xc9, 0x62],
                      [1.0, 0xfd, 0xe7, 0x25]])
    t = np.clip(t, 0, 1)
    out = np.empty(t.shape + (3,))
    for ch in range(3):
        out[..., ch] = np.interp(t, stops[:, 0], stops[:, ch + 1])
    return out


def write_heatmap(path, gains, title, vmax):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(6.6, 5.2), dpi=100)
        im = ax.imshow(gains, cmap="viridis", vmin=1.0, vmax=vmax,
                       interpolation="bilinear")
        ax.set_title(title)
        fig.colorbar(im, ax=ax, label="gain")
        fig.tight_layout()
        fig.savefig(path)
        plt.close(fig)
        return
    except ImportError:
        pass
    scale = 16
    t = (gains - 1.0) / max(vmax - 1.0, 1e-6)
    rgb = _colormap(np.kron(t, np.ones((scale, scale))))
    write_png_rgb(path, np.round(rgb))


def fmt_list(values, per_line=GRID_W, indent=" " * 14):
    rows = []
    vals = [f"{v:.4f}" for v in values]
    for i in range(0, len(vals), per_line):
        rows.append(", ".join(vals[i:i + per_line]))
    return "[\n" + indent + (",\n" + indent).join(rows) + " ]"


def lsc_block(sets, grid):
    """YAML text of the `- Lsc:` list item (indented for `algorithms:`)."""
    lines = ["  - Lsc:",
             f"      grid: [{grid[0]}, {grid[1]}]",
             "      sets:"]
    for ct, gains in sorted(sets, key=lambda s: s[0]):
        lines.append(f"        - ct: {int(ct)}")
        for c in CHANNELS:
            pad = " " * (3 - len(c))
            lines.append(f"          {c}:{pad}" + fmt_list(gains[c].ravel()))
    return "\n".join(lines) + "\n"


def full_tuning(block):
    return ("# SPDX-License-Identifier: CC0-1.0\n"
            "%YAML 1.1\n"
            "---\n"
            "# OV8858 (HP Pro x2 612 G2 rear camera, module 6BA803T2) on IPU3.\n"
            "# Lsc generated by tools/lsc/calibrate.py from flat-field captures.\n"
            "version: 1\n"
            "algorithms:\n"
            "  - Af:\n"
            "  - Agc:\n"
            "  - Awb:\n"
            "  - BlackLevelCorrection:\n"
            "  - ToneMapping:\n"
            + block + "...\n")


# --------------------------------------------------------------------------
# Calibration
# --------------------------------------------------------------------------
def expand_inputs(spec):
    if os.path.isdir(spec):
        files = sorted(glob.glob(os.path.join(spec, "*.bin")))
    else:
        files = sorted(glob.glob(spec))
    if not files:
        raise SystemExit(f"error: no raw files match '{spec}'")
    return files


def load_average(files, args, label):
    acc = None
    means = []
    clipped = 0
    for f in files:
        with open(f, "rb") as fh:
            buf = fh.read()
        img = unpack_ipu3_10(buf, args.width, args.height, args.stride)
        clipped = max(clipped, int(np.count_nonzero(img >= args.white - 2)))
        means.append(float(img.mean()))
        acc = img.astype(np.float64) if acc is None else acc + img
    avg = acc / len(files)
    m = np.array(means)
    print(f"[{label}] {len(files)} frame(s), mean raw level "
          f"{m.mean():.1f} (frame-to-frame spread "
          f"{100 * (m.max() - m.min()) / max(m.mean(), 1e-9):.2f} %)")
    if len(files) > 1 and (m.max() - m.min()) > 0.02 * m.mean():
        print(f"[{label}] WARNING: frame brightness varies by more than 2 % "
              "(AE still converging or flicker?)", file=sys.stderr)
    frac = clipped / (args.width * args.height)
    if frac > 1e-5:
        print(f"[{label}] WARNING: up to {clipped} pixels ({100 * frac:.3f} %) "
              f"per frame are at/near the white level {args.white}: the flat "
              "field is clipped, gains will be wrong. Reduce the light or "
              "exposure.", file=sys.stderr)
    return avg


def measure_black(args):
    files = expand_inputs(args.dark)
    avg = load_average(files, args, "dark")
    planes = split_planes(avg, args.bayer_order)
    # Ignore a border (amp glow / edge effects) and use the median.
    bl = {}
    for c, p in planes.items():
        h, w = p.shape
        bl[c] = float(np.median(p[h // 8:-h // 8, w // 8:-w // 8]))
    print("[dark] measured black level per channel: "
          + ", ".join(f"{c}={v:.2f}" for c, v in bl.items()))
    return bl


def calibrate_set(files, ct, black, args):
    avg = load_average(files, args, f"ct {ct}")
    planes = split_planes(avg, args.bayer_order)
    offsets = bayer_offsets(args.bayer_order)
    gy, gx = grid_positions(args.width, args.height, GRID_W, GRID_H)

    gains = {}
    stats = {}
    for c in CHANNELS:
        p = planes[c] - black[c]
        med, cy, cx = block_median(p, args.block)
        if args.smooth:
            med = smooth3(med)
        if np.min(med) <= 0:
            raise SystemExit(f"error: channel {c} has non-positive signal "
                             f"after black level subtraction (black={black[c]}, "
                             f"min block={np.min(med):.1f}); scene too dark or "
                             "black level too high")
        qy, qx = plane_coords(gy, gx, offsets[c])
        # Linear extrapolation to the array edge could in theory undershoot;
        # keep the response positive so gains stay finite (and get capped).
        resp = np.maximum(bilinear(med, cy, cx, qy, qx), 1e-3)
        peak = max(float(med.max()), float(resp.max()))
        g = peak / resp
        if args.max_gain:
            g = np.minimum(g, args.max_gain)
        gains[c] = g
        centre = float(bilinear(med, cy, cx, np.array([(p.shape[0] - 1) / 2]),
                                np.array([(p.shape[1] - 1) / 2]))[0, 0])
        corners = [resp[0, 0], resp[0, -1], resp[-1, 0], resp[-1, -1]]
        stats[c] = dict(peak=peak, centre=centre, corners=corners,
                        gmax=float(g.max()), level=peak + black[c])
        if peak + black[c] < 0.15 * args.white:
            print(f"[ct {ct}] WARNING: channel {c} peak level "
                  f"{peak + black[c]:.0f} is low; more light gives less noise",
                  file=sys.stderr)
        if args.max_gain and np.any(peak / resp > args.max_gain):
            n = int(np.count_nonzero(peak / resp > args.max_gain))
            print(f"[ct {ct}] note: {n} {c} grid point(s) capped at "
                  f"max gain {args.max_gain}", file=sys.stderr)
    return gains, stats


def print_summary(ct, stats):
    print(f"\nSummary for ct {ct} K (response after black level subtraction)")
    print("  chan   peak    centre  corner/centre (TL TR BL BR)      "
          "max gain")
    for c in CHANNELS:
        s = stats[c]
        ratios = " ".join(f"{v / s['centre']:.3f}" for v in s["corners"])
        print(f"  {c:<4} {s['peak']:7.1f} {s['centre']:8.1f}   {ratios}"
              f"            {s['gmax']:.3f}")
    gm = [(stats["gr"]["corners"][i] + stats["gb"]["corners"][i]) / 2
          for i in range(4)]
    gc = (stats["gr"]["centre"] + stats["gb"]["centre"]) / 2
    rg = [stats["r"]["corners"][i] / gm[i] / (stats["r"]["centre"] / gc)
          for i in range(4)]
    bg = [stats["b"]["corners"][i] / gm[i] / (stats["b"]["centre"] / gc)
          for i in range(4)]
    print("  colour shading, corner vs centre: R/G "
          + " ".join(f"{v:.3f}" for v in rg)
          + "   B/G " + " ".join(f"{v:.3f}" for v in bg))


def parse_args(argv):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*",
                    help="raw .bin files / directories / globs for a single "
                         "set (colour temperature from --ct)")
    ap.add_argument("--ct", type=int, default=5000,
                    help="colour temperature in K of the positional inputs "
                         "(default 5000)")
    ap.add_argument("--set", action="append", default=[], metavar="CT=PATH",
                    help="additional set: colour temperature and a directory "
                         "or glob of raw files, e.g. 2856=captures/a/ "
                         "(repeatable)")
    ap.add_argument("--width", type=int, default=WIDTH)
    ap.add_argument("--height", type=int, default=HEIGHT)
    ap.add_argument("--stride", type=int, default=None,
                    help="bytes per line (default: file size / height; the "
                         "CIO2 driver uses ceil(width/50)*64 = 4224)")
    ap.add_argument("--bayer-order", default="BGGR",
                    help="Bayer order of the raw frames (default BGGR)")
    ap.add_argument("--black-level", type=float, default=16.0,
                    help="black level at 10 bit (default 16: the OV8858 "
                         "BLC target, which the patched libcamera's IPU3 "
                         "BlackLevelCorrection subtracts; stock libcamera "
                         "0.7.2 subtracts 64)")
    ap.add_argument("--dark", metavar="PATH",
                    help="directory/glob of dark frames (lens covered); "
                         "measured per-channel black level overrides "
                         "--black-level")
    ap.add_argument("--white", type=int, default=WHITE,
                    help="white (saturation) level, default 1023")
    ap.add_argument("--block", type=int, default=32,
                    help="block-median tile size in colour-plane pixels "
                         "(default 32 = 64 sensor pixels)")
    ap.add_argument("--no-smooth", dest="smooth", action="store_false",
                    help="disable 3x3 smoothing of the block medians")
    ap.add_argument("--max-gain", type=float, default=8.0,
                    help="cap gains at this value (default 8.0, 0 = no cap; "
                         "the OV8858 red corners need about 7)")
    ap.add_argument("-o", "--outdir", default="lsc-out",
                    help="output directory (default ./lsc-out)")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.width % 2 or args.height % 2:
        raise SystemExit("error: width and height must be even")

    sets_in = []
    if args.inputs:
        files = []
        for spec in args.inputs:
            files += expand_inputs(spec)
        sets_in.append((args.ct, files))
    for s in args.set:
        ct, _, path = s.partition("=")
        if not path:
            raise SystemExit(f"error: --set expects CT=PATH, got '{s}'")
        sets_in.append((int(ct), expand_inputs(path)))
    if not sets_in:
        raise SystemExit("error: no input frames (give files or --set)")
    cts = [ct for ct, _ in sets_in]
    if len(set(cts)) != len(cts):
        raise SystemExit("error: duplicate colour temperature")

    if args.dark:
        black = measure_black(args)
    else:
        black = {c: args.black_level for c in CHANNELS}
        print(f"black level: {args.black_level} (all channels)")

    os.makedirs(args.outdir, exist_ok=True)
    sets_out = []
    for ct, files in sets_in:
        gains, stats = calibrate_set(files, ct, black, args)
        sets_out.append((ct, gains))
        print_summary(ct, stats)
        vmax = max(float(g.max()) for g in gains.values())
        for c in CHANNELS:
            np.savetxt(os.path.join(args.outdir, f"gains-{ct}-{c}.txt"),
                       gains[c], fmt="%.4f")
            write_heatmap(os.path.join(args.outdir, f"heatmap-{ct}-{c}.png"),
                          gains[c], f"LSC gain {c} @ {ct} K", vmax)

    block = lsc_block(sets_out, (GRID_W, GRID_H))
    with open(os.path.join(args.outdir, "lsc.yaml"), "w") as f:
        f.write(block)
    with open(os.path.join(args.outdir, "ov8858.yaml"), "w") as f:
        f.write(full_tuning(block))
    print(f"\nwrote {args.outdir}/lsc.yaml, {args.outdir}/ov8858.yaml, "
          "heatmap-*.png and gains-*.txt")
    return sets_out


if __name__ == "__main__":
    main()
