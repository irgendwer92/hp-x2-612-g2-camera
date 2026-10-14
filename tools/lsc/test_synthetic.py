#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
End-to-end test of calibrate.py without hardware.

Generates synthetic IPU3-packed SBGGR10 flat-field frames (3264x2448) with a
known per-channel cos^4 falloff (different strength and optical centre per
channel, i.e. vignetting plus colour shading), black level, shot and read
noise; runs calibrate.py on them and compares the recovered 33x25 gains with
the analytic ones. Also checks dark-frame black-level measurement, the gain
cap, and the generated YAML.

Usage: test_synthetic.py [--keep DIR] [--tol PERCENT]
"""

import argparse
import os
import re
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import calibrate as cal  # noqa: E402

W, H = cal.WIDTH, cal.HEIGHT
BLACK = 64
# Per channel: peak level above black (DN), effective focal length in units
# of the half-diagonal (smaller = stronger falloff), optical centre offset
# (fraction of width/height). Red falls off fastest, like the real module.
SHADING = {
    "r":  dict(peak=620.0, f=1.05, cx=0.02, cy=-0.015),
    "gr": dict(peak=780.0, f=1.30, cx=0.0, cy=0.0),
    "gb": dict(peak=775.0, f=1.32, cx=0.005, cy=0.0),
    "b":  dict(peak=560.0, f=1.45, cx=-0.01, cy=0.01),
}


def shading(c, y, x):
    """Analytic response (above black) at full-array coordinates."""
    p = SHADING[c]
    hd = 0.5 * np.hypot(W - 1, H - 1)
    dx = (x - (W - 1) * (0.5 + p["cx"])) / hd
    dy = (y - (H - 1) * (0.5 + p["cy"])) / hd
    r = np.hypot(dx, dy)
    cos_t = p["f"] / np.sqrt(p["f"] ** 2 + r ** 2)
    return p["peak"] * cos_t ** 4


def make_frame(rng, dark=False):
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float64)
    img = np.zeros((H, W))
    if not dark:
        for c, (dy, dx) in cal.bayer_offsets("BGGR").items():
            img[dy::2, dx::2] = shading(c, yy[dy::2, dx::2], xx[dy::2, dx::2])
        # Shot noise with ~4 e-/DN conversion gain.
        img = rng.poisson(img * 4.0) / 4.0
    img = img + BLACK + rng.normal(0, 2.0, img.shape)
    return np.clip(np.round(img), 0, 1023).astype(np.uint16)


def expected_gains(cap):
    gy, gx = cal.grid_positions(W, H, cal.GRID_W, cal.GRID_H)
    out = {}
    for c, off in cal.bayer_offsets("BGGR").items():
        # Sample the analytic surface at the plane sample nearest to each grid
        # point; the peak is the analytic maximum (the optical centre).
        Y, X = np.meshgrid(gy, gx, indexing="ij")
        resp = shading(c, Y, X)
        g = SHADING[c]["peak"] / resp
        out[c] = np.minimum(g, cap) if cap else g
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", help="write frames/output here and keep them")
    ap.add_argument("--frames", type=int, default=4)
    ap.add_argument("--tol", type=float, default=3.0,
                    help="max allowed relative gain error in percent")
    args = ap.parse_args()

    tmp = args.keep or tempfile.mkdtemp(prefix="lsc-synth-")
    flat_dir = os.path.join(tmp, "flat")
    dark_dir = os.path.join(tmp, "dark")
    os.makedirs(flat_dir, exist_ok=True)
    os.makedirs(dark_dir, exist_ok=True)

    rng = np.random.default_rng(1234)
    print(f"generating {args.frames} flat + 2 dark synthetic frames in {tmp}")
    for i in range(args.frames):
        buf = cal.pack_ipu3_10(make_frame(rng))
        assert len(buf) == 4224 * H
        with open(os.path.join(flat_dir, f"frame-cam0-stream1-{i:06d}.bin"),
                  "wb") as f:
            f.write(buf)
    for i in range(2):
        with open(os.path.join(dark_dir, f"dark-{i:06d}.bin"), "wb") as f:
            f.write(cal.pack_ipu3_10(make_frame(rng, dark=True)))

    failures = 0

    def check(name, got, want, tol):
        nonlocal failures
        err = np.abs(got / want - 1.0) * 100
        ok = err.max() <= tol
        failures += not ok
        print(f"  {name:<28} max err {err.max():5.2f} %  mean err "
              f"{err.mean():5.2f} %  corner gain got/want "
              f"{got[0, 0]:.3f}/{want[0, 0]:.3f}, {got[-1, -1]:.3f}/"
              f"{want[-1, -1]:.3f}  {'OK' if ok else 'FAIL'}")

    # 1. Fixed black level (the true one), no cap in effect (gains < 4).
    out1 = os.path.join(tmp, "out-fixed")
    sets = cal.main([flat_dir, "--ct", "5000", "--black-level", str(BLACK),
                     "-o", out1])
    gains = sets[0][1]
    want = expected_gains(0)
    print("\nrecovered vs analytic gains (black level 64, no cap reached):")
    for c in cal.CHANNELS:
        check(c, gains[c], want[c], args.tol)
        if gains[c].min() < 1.0:
            print(f"  FAIL: {c} has gain < 1.0")
            failures += 1

    # 2. Black level measured from dark frames.
    out2 = os.path.join(tmp, "out-dark")
    sets = cal.main(["--set", f"5000={flat_dir}", "--dark", dark_dir,
                     "-o", out2])
    print("\nwith black level measured from dark frames:")
    for c in cal.CHANNELS:
        check(c, sets[0][1][c], want[c], args.tol)

    # 3. Gain cap.
    out3 = os.path.join(tmp, "out-cap")
    sets = cal.main([flat_dir, "--black-level", str(BLACK), "--max-gain",
                     "1.8", "-o", out3])
    want_cap = expected_gains(1.8)
    print("\nwith --max-gain 1.8:")
    for c in cal.CHANNELS:
        g = sets[0][1][c]
        if g.max() > 1.8 + 1e-9:
            print(f"  FAIL: {c} exceeds cap")
            failures += 1
        check(c + " (capped)", g, want_cap[c], args.tol)

    # 4. YAML structure.
    print("\nYAML checks:")
    text = open(os.path.join(out1, "ov8858.yaml")).read()
    algos = re.findall(r"^  - (\w+):", text, re.M)
    ok = algos == ["Af", "Agc", "Awb", "BlackLevelCorrection", "ToneMapping",
                   "Lsc"]
    print(f"  algorithm order {algos} {'OK' if ok else 'FAIL'}")
    failures += not ok
    ok = "version: 1" in text and "grid: [33, 25]" in text
    print(f"  version/grid present {'OK' if ok else 'FAIL'}")
    failures += not ok
    try:
        import yaml  # optional
        doc = yaml.safe_load(text)
        lsc = doc["algorithms"][5]["Lsc"]
        for c in cal.CHANNELS:
            assert len(lsc["sets"][0][c]) == 33 * 25
            assert np.allclose(np.array(lsc["sets"][0][c]).reshape(25, 33),
                               gains[c], atol=1e-4)
        print("  parsed with PyYAML, 4 x 825 values, row-major OK")
    except ImportError:
        for c in cal.CHANNELS:
            m = re.search(rf"^ +{c}: +\[([^\]]*)\]", text, re.M)
            vals = [float(v) for v in m.group(1).replace("\n", " ").split(",")]
            ok = len(vals) == 825 and np.allclose(
                np.array(vals).reshape(25, 33), gains[c], atol=1e-4)
            failures += not ok
            print(f"  {c}: {len(vals)} values, row-major match "
                  f"{'OK' if ok else 'FAIL'}")

    print(f"\n{'PASS' if not failures else f'FAIL ({failures})'}; output in {tmp}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
