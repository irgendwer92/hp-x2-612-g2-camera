#!/bin/sh
# Build ov8858.ko with the bring-up diagnostics from debug/ on top of patches/.
# Output: build/debug/ov8858.ko. Run as a normal user; see scripts/debug-probe.sh.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
kver=${1:-$(uname -r)}
tag=$("$repo/scripts/prepare.sh" --tag "$kver")
"$repo/scripts/prepare.sh" "$kver"
out=$repo/build/debug
rm -rf "$out" && mkdir -p "$out/drivers/media/i2c"
cp "$repo/build/$tag/src/drivers/media/i2c/ov8858.c" "$out/drivers/media/i2c/"
for p in "$repo"/debug/*.patch; do
	patch -d "$out" -p1 --forward --batch < "$p"
done
cp "$out/drivers/media/i2c/ov8858.c" "$out/ov8858.c"
echo 'obj-m := ov8858.o' > "$out/Kbuild"
make -C "/lib/modules/$kver/build" M="$out" modules
echo "built $out/ov8858.ko"
