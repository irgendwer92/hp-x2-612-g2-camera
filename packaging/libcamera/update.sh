#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build Arch's current libcamera with the HP Pro x2 612 G2 patches from
# ../../libcamera/patches/ (front camera support, IPU3 lens shading, black
# level, digital gain) and install it in place of the stock packages.
#
# Steps: clone or update Arch's libcamera packaging into ./arch-upstream, copy
# its pkgver/pkgrel into ./PKGBUILD (the result is pkgrel + ".1", so it is
# newer than the stock build of the same version), then run makepkg.
#
# Run as your user, from anywhere; makepkg asks for sudo to install the build
# dependencies and the result. Needs base-devel, git and network access.
#   packaging/libcamera/update.sh                sync, build and install
#   packaging/libcamera/update.sh --no-install   sync and build only
#
# If ../../lsc-out/ov8858.yaml exists (your own calibration from tools/lsc),
# it is packaged as the OV8858 tuning file; otherwise the identity
# (uncorrected) lens shading table from the patches is used.
set -eu

case "${1:-}" in
"" | --no-install) ;;
*) echo "usage: $0 [--no-install]" >&2; exit 2 ;;
esac
[ "$(id -u)" != 0 ] || { echo "run as your user, not as root (makepkg asks for sudo)" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

if [ -d arch-upstream/.git ]; then
	git -C arch-upstream pull -q --ff-only
else
	git clone -q https://gitlab.archlinux.org/archlinux/packaging/packages/libcamera.git arch-upstream
fi
ver=$(sed -n 's/^pkgver=//p' arch-upstream/PKGBUILD)
rel=$(sed -n 's/^pkgrel=//p' arch-upstream/PKGBUILD)
[ -n "$ver" ] && [ -n "$rel" ] || { echo "cannot read Arch's pkgver/pkgrel" >&2; exit 1; }

npatches=0
for p in ../../libcamera/patches/*.patch; do
	[ -e "$p" ] && npatches=$((npatches + 1))
done

old=$(sed -n 's/^pkgver=//p' PKGBUILD)
sed -i "s/^pkgver=.*/pkgver=$ver/; s/^_archrel=.*/_archrel=$rel/" PKGBUILD
echo "Arch libcamera $ver-$rel -> building $ver-$rel.1 with $npatches patches"
[ "$old" = "$ver" ] || echo "note: new upstream version ($old -> $ver); if a patch no longer applies, the series in libcamera/patches/ needs a rebase"
if [ -f ../../lsc-out/ov8858.yaml ]; then
	echo "using the lens shading calibration in lsc-out/ov8858.yaml"
else
	echo "no lsc-out/ov8858.yaml: the rear camera gets no lens shading correction (see tools/lsc/README.md)"
fi

if [ "${1:-}" = --no-install ]; then
	makepkg -sf
else
	makepkg -sfi
fi
