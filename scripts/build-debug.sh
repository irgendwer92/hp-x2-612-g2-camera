#!/bin/sh
# Build all three modules with the bring-up experiments from debug/*.patch
# applied on top of patches/. Output: build/debug/*.ko (the normal build in the
# repo root is left alone). Run as a normal user, then e.g.
#   sudo scripts/test-load.sh build/debug
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
