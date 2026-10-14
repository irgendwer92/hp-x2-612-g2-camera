#!/bin/sh
# Fetch the pristine upstream sources this project patches.
# Usage: scripts/fetch-sources.sh <kernel-tag> <dest-dir>   e.g. v7.2.9 build/src
set -eu
tag=$1; dest=$2
base="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain"
files="
drivers/platform/x86/intel/int3472/tps68470.c
drivers/platform/x86/intel/int3472/tps68470.h
drivers/platform/x86/intel/int3472/tps68470_board_data.c
drivers/media/pci/intel/ipu-bridge.c
drivers/media/i2c/ov8858.c
"
for f in $files; do
	mkdir -p "$dest/$(dirname "$f")"
	curl -sSfL -o "$dest/$f" "$base/$f?h=$tag"
done
echo "fetched $(echo $files | wc -w) files for $tag into $dest"
