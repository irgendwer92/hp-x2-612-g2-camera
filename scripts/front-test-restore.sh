#!/bin/sh
# Undo scripts/front-test.sh arm: remove the boot-time rules and the staged
# test modules, so no later boot can pick them up.
#   sudo scripts/front-test-restore.sh
#
# This does not (and cannot) take INT347F out of the current boot's camera
# graph: ipu-bridge attaches the graph to the CIO2 device once per boot, and a
# reloaded ipu-bridge (test or DKMS build) reuses it as is. So:
#   - test boot where imx241 bound: both cameras work; nothing else to do.
#   - test boot where imx241 did not bind: ipu3-cio2 waits for it and the rear
#     camera is unavailable until the next normal boot. Reloading ipu3_cio2,
#     ov8858, dw9714 or ipu_bridge does not change that, so this script does
#     not try; reboot without hpcam_front_test.
#   - normal boot: the rules were inactive; nothing changes.
set -eu

conf=/etc/modprobe.d/hp-x2-612-g2-camera-front-test.conf
stage=/var/lib/hp-x2-612-g2-camera/front-test

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

rm -f "$conf"
rm -rf "$stage"
rmdir /var/lib/hp-x2-612-g2-camera 2>/dev/null || true
echo "removed $conf and $stage"

if grep -qw hpcam_front_test /proc/cmdline; then
	drv=$(basename "$(readlink /sys/bus/i2c/devices/i2c-INT347F:00/driver 2>/dev/null)" 2>/dev/null || true)
	if [ "$drv" = imx241 ]; then
		echo "this is a test boot and imx241 is bound: the rear camera works in this boot."
	else
		echo "this is a test boot and imx241 is NOT bound: the rear camera stays unavailable"
		echo "until you reboot (without hpcam_front_test)."
	fi
else
	echo "normal boot: nothing else to do."
fi
