#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# DEVELOPER / BRING-UP TOOL, not part of the normal install.
# Build the modules with the OV8858 bring-up diagnostics from debug/*.patch
# applied on top of patches/ (module parameters dbg_settle_ms, dbg_hold_s,
# dbg_reset_raw, dbg_pwdn_raw; see debug/0100-*.patch). Output:
# build/debug/*.ko (the normal build in the repo root is left alone).
# Needs the kernel headers for the target kernel. Run as a normal user:
#   scripts/build-debug.sh [kernelrelease]      (default: uname -r)
# then e.g.  sudo scripts/test-load.sh build/debug
# Used by scripts/debug-*.sh, which hold the sensor powered after a failed
# chip-ID read; that was needed before the OV8858 answered at all.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
kver=${1:-$(uname -r)}
tag=$("$repo/scripts/prepare.sh" --tag "$kver")
"$repo/scripts/prepare.sh" "$kver"
out=$repo/build/debug
rm -rf "$out" && mkdir -p "$out"
cp -r "$repo/build/$tag/src" "$out/src"
for p in "$repo"/debug/*.patch; do
	echo "applying $(basename "$p")"
	patch -d "$out/src" -p1 --forward --batch < "$p"
done
cp "$repo/Kbuild" "$out/Kbuild"
make -C "/lib/modules/$kver/build" M="$out" HPCAM_SRC=src modules
ls "$out"/*.ko
