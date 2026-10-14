#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Quick PNG preview of a raw IPU3-packed 10-bit Bayer capture.

Reads one frame of a file written by `v4l2-ctl --stream-to` from an ipu3-cio2
video node (V4L2_PIX_FMT_IPU3_S????10, several frames may be concatenated),
unpacks it with tools/lsc/calibrate.py's unpacker and writes a half-resolution
RGB preview: black level subtracted, grey-world white balance, gamma 2.2.
This is a sanity check of the sensor data path, not image processing.

  tools/raw2png.py capture.raw 2592 1944 RGGB -o preview.png
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lsc"))
from calibrate import cio2_stride, split_planes, unpack_ipu3_10, write_png_rgb  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raw")
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("order", help="Bayer order of the frame, e.g. RGGB or BGGR")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--frame", type=int, default=-1,
                    help="frame index in the file (default: last complete frame)")
    ap.add_argument("--stride", type=int, default=None,
                    help="bytes per line (default: ipu3-cio2's)")
    ap.add_argument("--black", type=float, default=64.0,
                    help="black level at 10 bit (default 64)")
    ap.add_argument("--no-wb", action="store_true", help="skip grey-world white balance")
    args = ap.parse_args(argv)

    stride = args.stride or cio2_stride(args.width)
    frame_size = stride * args.height
    data = open(args.raw, "rb").read()
    nframes = len(data) // frame_size
    if nframes == 0:
        sys.exit(f"{args.raw}: {len(data)} bytes, less than one frame ({frame_size})")
    idx = args.frame if args.frame >= 0 else nframes - 1
    if idx >= nframes:
        sys.exit(f"{args.raw}: only {nframes} complete frame(s)")
    buf = data[idx * frame_size:(idx + 1) * frame_size]

    img = unpack_ipu3_10(buf, args.width, args.height, stride).astype(np.float32)
    planes = split_planes(img, args.order)
    r = planes["r"] - args.black
    g = (planes["gr"] + planes["gb"]) / 2 - args.black
    b = planes["b"] - args.black
    rgb = np.clip(np.dstack([r, g, b]), 0, None)

    means = rgb.reshape(-1, 3).mean(axis=0)
    print(f"frame {idx}/{nframes}: raw mean {img.mean():.1f}, min {img.min():.0f}, "
          f"max {img.max():.0f}; R/G/B means after black {means.round(1).tolist()}")
    if not args.no_wb and means[1] > 0:
        gains = np.clip(means[1] / np.maximum(means, 1e-3), 0.25, 4.0)
        rgb *= gains
    scale = np.percentile(rgb, 99.5)
    rgb = np.clip(rgb / max(scale, 1e-3), 0, 1) ** (1 / 2.2)
    write_png_rgb(args.output, (rgb * 255 + 0.5).astype(np.uint8))
    print(f"wrote {args.output} ({rgb.shape[1]}x{rgb.shape[0]})")


if __name__ == "__main__":
    main(sys.argv[1:])
