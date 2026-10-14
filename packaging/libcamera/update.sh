#!/bin/sh
# Sync this package with Arch's current libcamera packaging and rebuild it
# with the HP Pro x2 612 G2 patches. Run as your user; makepkg asks for sudo
# to install build dependencies and the result.
#   ./update.sh            sync, build and install
#   ./update.sh --no-install
set -eu
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

old=$(sed -n 's/^pkgver=//p' PKGBUILD)
sed -i "s/^pkgver=.*/pkgver=$ver/; s/^_archrel=.*/_archrel=$rel/" PKGBUILD
echo "Arch libcamera $ver-$rel -> building $ver-$rel.1 with $(ls ../../libcamera/patches/*.patch | wc -l) patches"
[ "$old" = "$ver" ] || echo "note: new upstream version ($old -> $ver); if a patch no longer applies, rebase the series in ~/Projects/libcamera"

if [ "${1:-}" = --no-install ]; then
	makepkg -sf
else
	makepkg -sfi
fi
