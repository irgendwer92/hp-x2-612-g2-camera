#!/bin/sh
# Load the diagnostic ov8858 build and capture the power/clock/GPIO state while
# the sensor is held powered after a failed chip-ID read.
# Run as root after `sudo scripts/test-load.sh` (PMIC + bridge must be loaded)
# and `scripts/build-debug.sh`:
#   sudo scripts/debug-probe.sh [settle_ms]      (default 20)
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
ko=$repo/build/debug/ov8858.ko
settle=${1:-20}
hold=8
dbg=/sys/kernel/debug

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
[ -f "$ko" ] || { echo "$ko missing; run scripts/build-debug.sh first" >&2; exit 1; }
[ -e /sys/bus/i2c/devices/i2c-INT3477:00 ] || { echo "sensor device not present; run test-load.sh first" >&2; exit 1; }
mountpoint -q $dbg || mount -t debugfs none $dbg

say() { printf '\n==> %s\n' "$*"; }
mark=$(dmesg | wc -l)

[ -d /sys/module/ov8858 ] && rmmod ov8858
say "insmod debug ov8858 (dbg_settle_ms=$settle dbg_hold_s=$hold)"
insmod "$ko" dbg_settle_ms="$settle" dbg_hold_s="$hold" &
loader=$!

# Wait until the driver either succeeds or starts holding power.
i=0
while [ $i -lt 100 ]; do
	dmesg | tail -n +"$((mark + 1))" | grep -qE 'dbg: ID read failed|ov8858.*(probe|Detected)' && break
	sleep 0.1; i=$((i + 1))
done
dmesg | tail -n +"$((mark + 1))" | grep -E 'ov8858|tps68470|INT3477' | sed 's/^/  /'

if dmesg | tail -n +"$((mark + 1))" | grep -q 'dbg: ID read failed'; then
	say "regulators (powered, during hold)"
	grep -E 'regulator|tps68470|CORE|ANA|VCM|VIO|VSIO|AUX|INT3477' $dbg/regulator/regulator_summary 2>&1 | sed 's/^/  /'
	say "clocks"
	grep -iE 'clock|tps68470|INT3477|xvclk' $dbg/clk/clk_summary 2>&1 | sed 's/^/  /'
	say "PMIC GPIOs"
	awk '/tps68470/{p=1} p&&/^$/{exit} p' $dbg/gpio 2>&1 | sed 's/^/  /'
	if command -v i2cdetect >/dev/null; then
		say "i2c bus scan (bus of the PMIC/sensor)"
		bus=$(basename "$(readlink -f /sys/bus/i2c/devices/i2c-INT3477:00/..)")
		echo "  $bus"
		i2cdetect -y -r "${bus#i2c-}" 2>&1 | sed 's/^/  /'
		say "TPS68470 registers (read-only dump)"
		i2cdump -f -y "${bus#i2c-}" 0x48 b 2>&1 | sed 's/^/  /'
	else
		say "i2c-tools not installed: skipping bus scan and PMIC dump"
	fi
fi
wait "$loader" || true

say "result"
dmesg | tail -n +"$((mark + 1))" | grep -E 'ov8858' | sed 's/^/  /'
