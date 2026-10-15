#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# DEVELOPER / BRING-UP TOOL, not part of the normal install.
# Historical: superseded by the imx241 driver (patches/0005).
#
# Front camera (INT347F) bring-up probe: power the sensor up with the Windows
# sequence, dump its ID registers, power it down, using the throw-away module
# in debug/front-probe/. Needs patch 0004 in the installed PMIC module (DKMS
# package installed, then reboot) and the kernel headers.
#   scripts/front-probe.sh            build only (as user)
#   sudo scripts/front-probe.sh run [module params, e.g. use_vcm=1]
# The probe module can only bind while imx241 is not bound (sudo rmmod imx241
# with the camera idle). It does not enable the VSIO rail, so the sensor only
# answers while the rear camera happens to be powered (see docs/hardware.md,
# "front camera needs VSIO").
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
out=$repo/build/front-probe
kver=$(uname -r)

if [ "${1:-}" != run ]; then
	mkdir -p "$out"
	cp "$repo"/debug/front-probe/imx241_probe.c "$repo"/debug/front-probe/Kbuild "$out"/
	make -C "/lib/modules/$kver/build" M="$out" modules
	echo "built $out/imx241_probe.ko; now: sudo $0 run"
	exit 0
fi
shift
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 run" >&2; exit 1; }
if [ -e /sys/bus/i2c/devices/i2c-INT347F:00/driver ]; then
	echo "i2c-INT347F:00 is already bound (imx241?); unload it first: sudo rmmod imx241" >&2
	exit 1
fi
[ -f "$out/imx241_probe.ko" ] || { echo "build first: $0" >&2; exit 1; }
[ -e /sys/bus/i2c/devices/i2c-INT347F:00 ] || { echo "i2c-INT347F:00 missing (PMIC not probed?)" >&2; exit 1; }
if [ ! -e /sys/bus/platform/devices/tps68470-regulator/driver ]; then
	echo "error: tps68470-regulator is not bound (check: journalctl -k -b | grep tps68470)" >&2
	exit 1
fi
if ! modinfo -n intel_skl_int3472_tps68470 | grep -q /updates/; then
	echo "warning: the PMIC module is not the DKMS one; patch 0004 may be missing" >&2
fi

mark=$(dmesg | wc -l)
[ -d /sys/module/imx241_probe ] && rmmod imx241_probe
insmod "$out/imx241_probe.ko" "$@" || true
rmmod imx241_probe 2>/dev/null || true
dmesg | tail -n +"$((mark + 1))" | grep -E 'INT347F|imx241|tps68470|designware' | sed 's/^/  /'
