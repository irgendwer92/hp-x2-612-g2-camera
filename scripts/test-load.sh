#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# DEVELOPER / BRING-UP TOOL. Not needed for a normal install (use the DKMS
# package in packaging/arch instead).
#
# Swap the in-tree camera modules for the ones built by `make`, without
# installing anything, then print a diagnostic report.
#   make                                         as your user
#   sudo scripts/test-load.sh [dir-with-.ko-files]   (default: repo root)
# Revert with:   sudo scripts/restore.sh   (or reboot)
#
# Safety: only works once per boot and only while the stock modules are in use
# (the PMIC driver consumes its ACPI dependency list on the first successful
# probe); it refuses to run otherwise. Stop PipeWire/WirePlumber first so no
# camera module is in use. Nothing is written outside /run.
#
# Load order (and why):
#   1. dependencies + TPS68470 cell drivers (clk_tps68470, tps68470_regulator,
#      gpio_tps68470) via modprobe. They must be bound before the sensors probe:
#      the sensor drivers' clock lookup silently falls back to a fake fixed
#      19.2 MHz clock (no -EPROBE_DEFER) if the tps68470 clkdev lookup is not
#      registered yet.
#   2. patched intel_skl_int3472_tps68470: the PMIC probes, registers the
#      regulators/clock/GPIO lookups, and satisfies the sensors' ACPI _DEP so
#      i2c-INT3477:00 (rear) and i2c-INT347F:00 (front) are enumerated.
#   3. patched ipu-bridge, then in-tree ipu3_cio2 (its ipu_bridge dependency is
#      already satisfied by our module, so modprobe will not load the in-tree one).
#      cio2 must come after step 2: ipu-bridge only builds the fwnode graph for
#      sensors whose ACPI device is ready for enumeration.
#   4. patched ov8858 and the new imx241 last, so they probe with clock,
#      regulators, GPIOs and the fwnode endpoint all in place. ipu3-cio2 only
#      registers its media graph once every sensor in the graph has bound, so
#      both sensor drivers are needed even to test only one camera.
# While testing, /run/modprobe.d/hp-x2-612-g2-camera-test.conf blacklists
# ov8858 and imx241 so udev does not autoload other copies when the sensor
# devices appear (between steps 2 and 4). It lives in /run, so it disappears on
# reboot; restore.sh removes it as well.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
kodir=${1:-$repo}
kver=$(uname -r)
blacklist=/run/modprobe.d/hp-x2-612-g2-camera-test.conf

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

say() { printf '\n==> %s\n' "$*"; }
die() { echo "test-load.sh: error: $*" >&2; exit 1; }

for m in intel_skl_int3472_tps68470 ipu-bridge ov8858 imx241; do
	f=$kodir/$m.ko
	[ -f "$f" ] || die "$f not found; run 'make' first"
	vm=$(modinfo -F vermagic "$f" | awk '{print $1}')
	[ "$vm" = "$kver" ] || die "$f was built for $vm, running kernel is $kver; run 'make'"
done

is_loaded() { [ -d "/sys/module/$1" ]; }
# insmod does not resolve dependencies; load those of $1 (a .ko) with modprobe.
load_deps() {
	deps=$(modinfo -F depends "$1" | tr , ' ')
	# shellcheck disable=SC2086 # word splitting intended: list of module names
	[ -z "$deps" ] || modprobe -a $deps
}
unload() {
	for m in "$@"; do
		if is_loaded "$m"; then
			echo "rmmod $m"
			rmmod "$m" || die "cannot unload $m (in use? stop camera users first, e.g. 'systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber' as your user)"
		fi
	done
}

# The PMIC driver finds its sensor through the ACPI _DEP list, which a
# successful probe consumes. A second probe in the same boot then fails with
# "INT3472 seems to have no dependents", so this test works once per boot.
if [ -e /sys/bus/i2c/devices/i2c-INT3477:00 ]; then
	die "the PMIC already probed in this boot (i2c-INT3477:00 exists); reboot, then run this again"
fi

dmesg_mark=$(dmesg | wc -l)

say "unloading in-tree modules"
# cio2 first: once the sensors are bound, v4l2 holds a reference on the sensor
# (and dw9714 lens) modules through cio2. dw9714 holds the VCM regulator, so it
# must go before the PMIC driver. Then the bridge, then the PMIC.
unload ipu3_cio2 ov8858 imx241 dw9714 ipu_bridge intel_skl_int3472_tps68470

mkdir -p /run/modprobe.d
{
	echo "# temporary, from hp-x2-612-g2-camera scripts/test-load.sh"
	echo "blacklist ov8858"
	echo "blacklist imx241"
} > "$blacklist"

say "loading dependencies and TPS68470 cell drivers"
modprobe -a intel_skl_int3472_common clk_tps68470 tps68470_regulator gpio_tps68470 \
	mc videodev v4l2_async v4l2_fwnode
for m in clk_tps68470 tps68470_regulator gpio_tps68470; do
	is_loaded "$m" || die "$m did not load"
done

say "insmod intel_skl_int3472_tps68470.ko (patched)"
insmod "$kodir/intel_skl_int3472_tps68470.ko"
udevadm settle -t 10 || true

say "insmod ipu-bridge.ko (patched), modprobe ipu3_cio2"
insmod "$kodir/ipu-bridge.ko"
modprobe ipu3_cio2
udevadm settle -t 10 || true

say "insmod ov8858.ko (patched) and imx241.ko (new)"
for m in ov8858 imx241; do
	if is_loaded "$m"; then
		echo "another $m got loaded anyway; replacing it"
		rmmod "$m"
	fi
	load_deps "$kodir/$m.ko"
	insmod "$kodir/$m.ko"
done
udevadm settle -t 10 || true
# The VCM i2c client survives module reloads; rebind its lens driver.
modprobe dw9714 2>/dev/null || true
sleep 1

say "loaded modules"
for m in intel_skl_int3472_tps68470 ipu_bridge ov8858 imx241 ipu3_cio2 clk_tps68470 tps68470_regulator gpio_tps68470; do
	if is_loaded "$m"; then
		src=$(cat "/sys/module/$m/taint" 2>/dev/null)
		printf '  %-28s loaded%s\n' "$m" "${src:+ (taint: $src)}"
	else
		printf '  %-28s NOT loaded\n' "$m"
	fi
done

say "devices"
for d in i2c-INT3472:05 i2c-INT3477:00 i2c-INT347F:00; do
	p=/sys/bus/i2c/devices/$d
	if [ -e "$p" ]; then
		drv=$(basename "$(readlink "$p/driver" 2>/dev/null)" 2>/dev/null)
		echo "  $d: driver=${drv:-<none>}"
	else
		echo "  $d: not present"
	fi
done
for p in /sys/bus/platform/devices/*tps68470*; do
	[ -e "$p" ] && echo "  platform: ${p##*/}"
done

say "kernel log since load (filtered)"
dmesg | tail -n +"$((dmesg_mark + 1))" |
	grep -Ei 'int3472|tps68470|ov8858|imx241|INT3477|INT347F|ipu3-cio2|ipu3_cio2|ipu-bridge|ipu_bridge|cio2|xvclk|regulator|dovdd|avdd|dvdd' || echo "  (no matching lines)"

say "clock check (xvclk)"
dmesg | tail -n +"$((dmesg_mark + 1))" | grep -Ei 'xvclk|Failed to set xvclk' ||
	echo "  (no xvclk messages)"

say "media topology: sensor entities"
media=""
command -v media-ctl >/dev/null || echo "  media-ctl not installed (v4l-utils)"
for m in /dev/media*; do
	[ -e "$m" ] || continue
	command -v media-ctl >/dev/null || break
	if media-ctl -d "$m" -p 2>/dev/null | grep -q 'ipu3-cio2'; then media=$m; break; fi
done
if [ -z "$media" ]; then
	echo "  no ipu3-cio2 media device (it is registered only after every sensor"
	echo "  in the graph has bound; see the kernel log above, or media-ctl is missing)"
else
	echo "  using $media"
	media-ctl -d "$media" -p 2>&1 | awk '
		/^- entity/ { show = ($0 ~ /ov8858|imx241/) }
		show { print "  " $0 }
		/^$/ { show = 0 }'
	media-ctl -d "$media" -p 2>/dev/null | grep -q ov8858 || echo "  (no ov8858 entity in $media)"
	media-ctl -d "$media" -p 2>/dev/null | grep -q imx241 || echo "  (no imx241 entity in $media)"
fi

say "libcamera: cam -l"
if command -v cam >/dev/null; then
	cam -l 2>&1 | sed 's/^/  /' || true
else
	echo "  cam not installed (libcamera-tools)"
fi

echo
echo "Done. Revert with: sudo $here/restore.sh"
