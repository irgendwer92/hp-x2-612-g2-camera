#!/bin/sh
# Front camera (INT347F) bring-up probe: power the sensor up with the Windows
# sequence, dump its ID registers, power it down. Needs patch 0004 in the
# installed PMIC module (rebuild/reinstall the DKMS package, then reboot).
#   scripts/front-probe.sh            build only (as user)
#   sudo scripts/front-probe.sh run [module params, e.g. use_vcm=1]
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
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
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
