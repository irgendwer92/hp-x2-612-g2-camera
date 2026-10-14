#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Unit tests for the IPU3 10-bit packed Bayer (un)packer in calibrate.py."""

import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import calibrate as cal  # noqa: E402


def libcamera_reference_unpack(line, width):
    """Python port of libcamera v0.7.2 src/apps/common/dng_writer.cpp
    packScanlineIPU3(), which expands one IPU3 line to 16 bit (value << 6).
    Used as an independent reference decoder."""
    out = []
    i = 0
    while True:
        for _ in range(6):
            b = line[i:i + 5]
            for v in ((b[1] & 0x03) << 14 | (b[0] & 0xff) << 6,
                      (b[2] & 0x0f) << 12 | (b[1] & 0xfc) << 4,
                      (b[3] & 0x3f) << 10 | (b[2] & 0xf0) << 2,
                      (b[4] & 0xff) << 8 | (b[3] & 0xc0) << 0):
                out.append(v >> 6)
                if len(out) >= width:
                    return out
            i += 5
        out.append(((line[i + 1] & 0x03) << 14 | (line[i] & 0xff) << 6) >> 6)
        if len(out) >= width:
            return out
        i += 2


class TestIpu3Packing(unittest.TestCase):
    def test_stride(self):
        # ipu3-cio2 cio2_bytesperline(): DIV_ROUND_UP(width, 50) * 64
        self.assertEqual(cal.cio2_stride(3264), 4224)
        self.assertEqual(cal.ipu3_min_stride(3264), 131 * 32)
        self.assertEqual(cal.cio2_stride(1632), 33 * 64)

    def test_kernel_doc_byte_layout(self):
        """Single-pixel patterns land in the bytes/bits that
        Documentation/userspace-api/media/v4l/pixfmt-srggb10-ipu3.rst gives:
        byte0 = P0[7:0]; byte1 = P1[5:0]<<2 | P0[9:8]; byte2 = P2[3:0]<<4 |
        P1[9:6]; byte3 = P3[1:0]<<6 | P2[9:4]; byte4 = P3[9:2]; ...
        byte31 bits 1..0 = P24[9:8], bits 7..2 padding."""
        cases = {
            0: {0: 0xff, 1: 0x03},
            1: {1: 0xfc, 2: 0x0f},
            2: {2: 0xf0, 3: 0x3f},
            3: {3: 0xc0, 4: 0xff},
            4: {5: 0xff, 6: 0x03},
            24: {30: 0xff, 31: 0x03},
        }
        for pix, expected in cases.items():
            img = np.zeros((1, 25), np.uint16)
            img[0, pix] = 0x3ff
            buf = cal.pack_ipu3_10(img, stride=32)
            want = bytearray(32)
            for k, v in expected.items():
                want[k] = v
            self.assertEqual(buf, bytes(want), f"pixel {pix}")
            self.assertTrue(np.array_equal(
                cal.unpack_ipu3_10(buf, 25, 1), img))

    def test_known_values(self):
        # P0 = 0x155, P1 = 0x2aa, P2 = 0x0f0, P3 = 0x30f
        img = np.zeros((1, 25), np.uint16)
        img[0, :4] = [0x155, 0x2aa, 0x0f0, 0x30f]
        buf = cal.pack_ipu3_10(img, stride=32)
        self.assertEqual(buf[0], 0x55)                                # P0 lo
        self.assertEqual(buf[1], ((0x2aa & 0x3f) << 2) | (0x155 >> 8))
        self.assertEqual(buf[2], ((0x0f0 & 0x0f) << 4) | (0x2aa >> 6))
        self.assertEqual(buf[3], ((0x30f & 0x03) << 6) | (0x0f0 >> 4))
        self.assertEqual(buf[4], 0x30f >> 2)

    def test_round_trip_random(self):
        rng = np.random.default_rng(1)
        for w, h in ((25, 3), (26, 2), (50, 4), (77, 5), (3264, 6)):
            img = rng.integers(0, 1024, size=(h, w), dtype=np.uint16)
            buf = cal.pack_ipu3_10(img)
            self.assertEqual(len(buf), cal.cio2_stride(w) * h)
            out = cal.unpack_ipu3_10(buf, w, h)        # stride auto-detected
            self.assertTrue(np.array_equal(out, img), f"{w}x{h}")
            # Explicit, tight stride as well.
            buf2 = cal.pack_ipu3_10(img, stride=cal.ipu3_min_stride(w))
            self.assertTrue(np.array_equal(
                cal.unpack_ipu3_10(buf2, w, h, cal.ipu3_min_stride(w)), img))

    def test_matches_libcamera_reference(self):
        rng = np.random.default_rng(2)
        w, h = 3264, 3
        img = rng.integers(0, 1024, size=(h, w), dtype=np.uint16)
        buf = cal.pack_ipu3_10(img)
        stride = cal.cio2_stride(w)
        ours = cal.unpack_ipu3_10(buf, w, h)
        for y in range(h):
            ref = libcamera_reference_unpack(buf[y * stride:(y + 1) * stride], w)
            self.assertEqual(ours[y].tolist(), ref)
            self.assertEqual(ref, img[y].tolist())

    def test_bayer_offsets(self):
        self.assertEqual(cal.bayer_offsets("BGGR"),
                         {"b": (0, 0), "gb": (0, 1), "gr": (1, 0), "r": (1, 1)})
        self.assertEqual(cal.bayer_offsets("RGGB"),
                         {"r": (0, 0), "gr": (0, 1), "gb": (1, 0), "b": (1, 1)})
        self.assertEqual(cal.bayer_offsets("GRBG"),
                         {"gr": (0, 0), "r": (0, 1), "b": (1, 0), "gb": (1, 1)})


if __name__ == "__main__":
    unittest.main()
