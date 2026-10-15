#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Prepare a patched source tree for one kernel version: fetch the pristine
# upstream driver files (scripts/fetch-sources.sh) and apply patches/*.patch.
# Called by `make`, `make dist` and the DKMS PKGBUILD; runs as a normal user
# and only writes below the build directory.
#
# Usage: scripts/prepare.sh [kernelrelease]       (default: uname -r)
#        scripts/prepare.sh --tag [kernelrelease]  (only print the upstream tag)
#
#   7.2.9-arch1-1 -> v7.2.9      7.3.0-arch1-1 -> v7.3      7.3.0-rc2-1-mainline -> v7.3-rc2
#
# Layout (BUILD_ROOT defaults to <repo>/build):
#   $BUILD_ROOT/<tag>/pristine/  pristine upstream files, fetched once (cache)
#   $BUILD_ROOT/<tag>/src/       pristine + patches/*.patch, regenerated on every run
#
# Environment:
#   BUILD_ROOT   override the build directory
#   PATCHES_DIR  override the patch directory (default: <repo>/patches)
#
# Prints the path of the patched tree as its last line of output.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")

die() { echo "prepare.sh: error: $*" >&2; exit 1; }

kver_to_tag() {
	# Accept 7.2.9-arch1-1, 7.2.9.arch1-1, 7.3.0-rc1, 7.3-rc2, ...
	v=$(printf '%s\n' "$1" | sed -n 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\)\(\.\([0-9][0-9]*\)\)\{0,1\}.*$/\1 \2 \4/p')
	[ -n "$v" ] || die "cannot derive an upstream tag from kernel release '$1'"
	rc=$(printf '%s\n' "$1" | sed -n 's/^[0-9.]*-rc\([0-9][0-9]*\).*$/\1/p')
	# shellcheck disable=SC2086 # split "major minor [patch]" into $1..$3
	set -- $v
	if [ -n "$rc" ]; then
		echo "v$1.$2-rc$rc"
	elif [ $# -lt 3 ] || [ "$3" = 0 ]; then
		echo "v$1.$2"
	else
		echo "v$1.$2.$3"
	fi
}

print_tag_only=0
if [ "${1:-}" = "--tag" ]; then
	print_tag_only=1
	shift
fi
kver=${1:-$(uname -r)}
tag=$(kver_to_tag "$kver")
if [ "$print_tag_only" = 1 ]; then
	echo "$tag"
	exit 0
fi

BUILD_ROOT=${BUILD_ROOT:-$repo/build}
PATCHES_DIR=${PATCHES_DIR:-$repo/patches}
top=$BUILD_ROOT/$tag
pristine=$top/pristine
src=$top/src

# Files fetch-sources.sh provides; used to validate the cache.
files="
drivers/platform/x86/intel/int3472/tps68470.c
drivers/platform/x86/intel/int3472/tps68470.h
drivers/platform/x86/intel/int3472/tps68470_board_data.c
drivers/media/pci/intel/ipu-bridge.c
drivers/media/i2c/ov8858.c
"

cache_ok() {
	for f in $files; do
		[ -s "$pristine/$f" ] || return 1
	done
	return 0
}

# 1. Fetch pristine sources (once per tag). Fetch into a temp dir and rename,
#    so an interrupted download never leaves a half-populated cache behind.
if cache_ok; then
	echo "using cached pristine sources for $tag ($pristine)"
else
	echo "fetching pristine sources for $tag ..."
	mkdir -p "$top"
	tmp=$(mktemp -d "$top/.pristine.XXXXXX")
	trap 'rm -rf "$tmp"' EXIT INT TERM
	"$here/fetch-sources.sh" "$tag" "$tmp" || die "fetching $tag failed (network? does tag $tag exist upstream?)"
	rm -rf "$pristine"
	mv "$tmp" "$pristine"
	trap - EXIT INT TERM
	cache_ok || die "fetched tree for $tag is incomplete"
fi

# 2. Fresh copy of the pristine tree, then apply every patch in order.
rm -rf "$src"
mkdir -p "$src"
cp -R "$pristine/." "$src/"

applied=""
n=0
for p in "$PATCHES_DIR"/*.patch; do
	[ -e "$p" ] || continue   # no patches yet: the glob did not match
	name=$(basename "$p")
	echo "applying $name"
	if ! out=$(patch -p1 --forward --batch --no-backup-if-mismatch -d "$src" -i "$p" 2>&1); then
		printf '%s\n' "$out" | sed 's/^/    /' >&2
		rej=$(find "$src" -name '*.rej' 2>/dev/null)
		[ -n "$rej" ] && printf 'reject files:\n%s\n' "$rej" >&2
		die "patch $name does not apply to $tag; the patched tree in $src is INCOMPLETE"
	fi
	printf '%s\n' "$out" | sed 's/^/    /'
	if printf '%s\n' "$out" | grep -qi 'fuzz'; then
		echo "    WARNING: $name applied with fuzz against $tag - review the result" >&2
	fi
	applied="$applied $name"
	n=$((n + 1))
done

# Provenance record (copied into DKMS trees by 'make dist').
{
	echo "tag=$tag"
	echo "kernelrelease=$kver"
	echo "patches=$n"
	for a in $applied; do echo "patch=$a"; done
} > "$src/VENDORED"

echo "prepared $tag with $n patch(es)"
echo "$src"
