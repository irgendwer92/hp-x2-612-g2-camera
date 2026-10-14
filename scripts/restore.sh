#!/bin/sh
# Revert from the test-loaded (patched) modules to the stock in-tree modules.
# Run as root:  sudo scripts/restore.sh
#
# The in-tree .ko files under /lib/modules/$(uname -r)/kernel are loaded by path,
# so this also works when the DKMS package is installed (which would otherwise
# win via /updates/dkms). To make the revert permanent with DKMS installed,
# remove the package (pacman -R hp-x2-612-g2-camera-dkms).
set -eu

kver=$(uname -r)
kdir=/lib/modules/$kver/kernel
blacklist=/run/modprobe.d/hp-x2-612-g2-camera-test.conf

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

is_loaded() { [ -d "/sys/module/$1" ]; }
unload() {
	for m in "$@"; do
		if is_loaded "$m"; then
			echo "rmmod $m"
			rmmod "$m" || { echo "cannot unload $m (in use? stop camera users first)" >&2; exit 1; }
		fi
	done
}
intree() {
	# $1 = path below $kdir without extension; the in-tree file may be compressed.
	for ext in .ko.zst .ko.xz .ko.gz .ko; do
		[ -f "$kdir/$1$ext" ] && { echo "$kdir/$1$ext"; return 0; }
	done
	echo "in-tree module $1 not found under $kdir" >&2
	exit 1
}

unload ipu3_cio2 ov8858 dw9714 ipu_bridge intel_skl_int3472_tps68470
rm -f "$blacklist"

modprobe -a intel_skl_int3472_common mc videodev v4l2_async v4l2_fwnode
echo "insmod in-tree intel_skl_int3472_tps68470"
insmod "$(intree drivers/platform/x86/intel/int3472/intel_skl_int3472_tps68470)"
echo "insmod in-tree ipu-bridge"
insmod "$(intree drivers/media/pci/intel/ipu-bridge)"
echo "modprobe ipu3_cio2"
modprobe ipu3_cio2
modprobe dw9714 2>/dev/null || true
# ov8858 is left unloaded: with stock board data the PMIC does not probe, so
# the sensor device never appears and udev would not load it anyway.

for m in intel_skl_int3472_tps68470 ipu_bridge ipu3_cio2 ov8858; do
	if is_loaded "$m"; then
		t=$(cat "/sys/module/$m/taint" 2>/dev/null)
		printf '  %-28s loaded%s\n' "$m" "${t:+ (taint: $t - NOT the in-tree module?)}"
	else
		printf '  %-28s not loaded\n' "$m"
	fi
done

if modinfo -n ov8858 2>/dev/null | grep -q /updates/; then
	echo "note: DKMS copies are installed under /updates and will be used at next boot."
fi
echo "restored in-tree modules for $kver"
