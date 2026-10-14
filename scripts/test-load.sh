#!/bin/sh
# Swap the in-tree camera modules for the ones built by `make`, then report.
# Run as root:   sudo scripts/test-load.sh [dir-with-.ko-files]   (default: repo root)
# Revert with:   sudo scripts/restore.sh
#
# Load order (and why):
#   1. dependencies + TPS68470 cell drivers (clk_tps68470, tps68470_regulator,
#      gpio_tps68470) via modprobe. They must be bound before the sensor probes:
#      ov8858 uses devm_v4l2_sensor_clk_get(), which silently falls back to a
#      fake fixed 19.2 MHz clock (no -EPROBE_DEFER) if the tps68470 clkdev lookup
#      is not registered yet.
#   2. patched intel_skl_int3472_tps68470: the PMIC probes, registers the
#      regulators/clock/GPIO lookups, and satisfies the sensor's ACPI _DEP so
#      i2c-INT3477:00 is enumerated.
#   3. patched ipu-bridge, then in-tree ipu3_cio2 (its ipu_bridge dependency is
#      already satisfied by our module, so modprobe will not load the in-tree one).
#      cio2 must come after step 2: ipu-bridge only builds the sensor's fwnode
#      graph for sensors whose ACPI device is ready for enumeration.
#   4. patched ov8858 last, so it probes with clock, regulators, GPIOs and the
#      fwnode endpoint all in place.
# While testing, /run/modprobe.d/hp-x2-612-g2-camera-test.conf blacklists the
# in-tree ov8858 so udev does not autoload it when i2c-INT3477:00 appears
# (between steps 2 and 4). It lives in /run, so it disappears on reboot;
# restore.sh removes it as well.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
kodir=${1:-$repo}
kver=$(uname -r)
blacklist=/run/modprobe.d/hp-x2-612-g2-camera-test.conf

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

say() { printf '\n==> %s\n' "$*"; }
die() { echo "test-load.sh: error: $*" >&2; exit 1; }

for m in intel_skl_int3472_tps68470 ipu-bridge ov8858; do
	f=$kodir/$m.ko
	[ -f "$f" ] || die "$f not found; run 'make' first"
	vm=$(modinfo -F vermagic "$f" | awk '{print $1}')
	[ "$vm" = "$kver" ] || die "$f was built for $vm, running kernel is $kver; run 'make'"
done

is_loaded() { [ -d "/sys/module/$1" ]; }
unload() {
	for m in "$@"; do
		if is_loaded "$m"; then
			echo "rmmod $m"
			rmmod "$m" || die "cannot unload $m (in use? stop camera users first, e.g. 'systemctl --user stop wireplumber pipewire' as your user)"
		fi
	done
}

dmesg_mark=$(dmesg | wc -l)

say "unloading in-tree modules"
# cio2 first: once the sensor is bound, v4l2 holds a reference on the ov8858
# (and dw9714 lens) modules through cio2. dw9714 holds the VCM regulator, so it
# must go before the PMIC driver. Then the bridge, then the PMIC.
unload ipu3_cio2 ov8858 dw9714 ipu_bridge intel_skl_int3472_tps68470

mkdir -p /run/modprobe.d
echo "blacklist ov8858   # temporary, from hp-x2-612-g2-camera scripts/test-load.sh" > "$blacklist"

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

say "insmod ov8858.ko (patched)"
if is_loaded ov8858; then
	echo "in-tree ov8858 got loaded anyway; replacing it"
	rmmod ov8858
fi
insmod "$kodir/ov8858.ko"
udevadm settle -t 10 || true
# The VCM i2c client survives module reloads; rebind its lens driver.
modprobe dw9714 2>/dev/null || true
sleep 1

say "loaded modules"
for m in intel_skl_int3472_tps68470 ipu_bridge ov8858 ipu3_cio2 clk_tps68470 tps68470_regulator gpio_tps68470; do
	if is_loaded "$m"; then
		src=$(cat "/sys/module/$m/taint" 2>/dev/null)
		printf '  %-28s loaded%s\n' "$m" "${src:+ (taint: $src)}"
	else
		printf '  %-28s NOT loaded\n' "$m"
	fi
done

say "devices"
for d in i2c-INT3472:05 i2c-INT3477:00; do
	p=/sys/bus/i2c/devices/$d
	if [ -e "$p" ]; then
		drv=$(basename "$(readlink "$p/driver" 2>/dev/null)" 2>/dev/null)
		echo "  $d: driver=${drv:-<none>}"
	else
		echo "  $d: not present"
	fi
done
ls /sys/bus/platform/devices 2>/dev/null | grep -i tps68470 | sed 's/^/  platform: /' || true

say "kernel log since load (filtered)"
dmesg | tail -n +"$((dmesg_mark + 1))" |
	grep -Ei 'int3472|tps68470|ov8858|INT3477|ipu3-cio2|ipu3_cio2|ipu-bridge|ipu_bridge|cio2|xvclk|regulator|dovdd|avdd|dvdd' || echo "  (no matching lines)"

say "clock check (xvclk)"
dmesg | tail -n +"$((dmesg_mark + 1))" | grep -Ei 'xvclk|Failed to set xvclk' ||
	echo "  (no xvclk messages)"

say "media topology: sensor entity"
media=""
for m in /dev/media*; do
	[ -e "$m" ] || continue
	if media-ctl -d "$m" -p 2>/dev/null | grep -q 'ipu3-cio2'; then media=$m; break; fi
done
media=${media:-/dev/media1}
echo "  using $media"
if command -v media-ctl >/dev/null; then
	media-ctl -d "$media" -p 2>&1 | awk '
		/^- entity/ { show = ($0 ~ /ov8858/) }
		show { print "  " $0 }
		/^$/ { show = 0 }'
	media-ctl -d "$media" -p 2>/dev/null | grep -q ov8858 || echo "  (no ov8858 entity in $media)"
else
	echo "  media-ctl not installed (v4l-utils)"
fi

say "libcamera: cam -l"
if command -v cam >/dev/null; then
	cam -l 2>&1 | sed 's/^/  /' || true
else
	echo "  cam not installed (libcamera-tools)"
fi

echo
echo "Done. Revert with: sudo $here/restore.sh"
