#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Fetch the pristine upstream sources this project patches (5 files, from the
# stable tree on git.kernel.org; needs curl and network access). Normally
# called by scripts/prepare.sh, which caches the result per tag.
# Usage: scripts/fetch-sources.sh <kernel-tag> <dest-dir>   e.g. v7.2.9 build/src
# drivers/media/i2c/imx241.c is not fetched: patches/0005 creates it.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <kernel-tag> <dest-dir>" >&2; exit 2; }
tag=$1; dest=$2
base="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain"
files="
drivers/platform/x86/intel/int3472/tps68470.c
drivers/platform/x86/intel/int3472/tps68470.h
drivers/platform/x86/intel/int3472/tps68470_board_data.c
drivers/media/pci/intel/ipu-bridge.c
drivers/media/i2c/ov8858.c
"
n=0
for f in $files; do
	mkdir -p "$dest/$(dirname "$f")"
	curl -sSfL -o "$dest/$f" "$base/$f?h=$tag"
	n=$((n + 1))
done
echo "fetched $n files for $tag into $dest"
