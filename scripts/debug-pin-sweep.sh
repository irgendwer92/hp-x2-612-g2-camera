#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# DEVELOPER / BRING-UP TOOL, not part of the normal install.
# Historical: written while the OV8858 did not answer on I2C (see the
# bring-up log in docs/hardware.md). Drives PMIC GPIOs directly: if the bus
# wedges, power the machine off completely (a reboot is not enough).
#
# Bring-up experiment 2: test the polarity of the sensor reset/powerdown lines
# (TPS68470 s_resetn = 9, s_enable = 7) and the s_idle output (8).
# With the sensor held powered by the diagnostic ov8858 build, set every
# combination of raw levels and read the OV8858 chip ID (0x300a, expect
# 00 88 58) at 0x10 / 0x36. Also dumps the TPS68470 registers (read-only).
# GPIO1/2 are never touched (I2C daisy chain). Targeted reads only.
# Needs libgpiod (v2) + i2c-tools; run test-load.sh and build-debug.sh first.
#   sudo scripts/debug-pin-sweep.sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
ko=$repo/build/debug/ov8858.ko
hold=60
par=/sys/module/ov8858/parameters

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
for t in gpioset gpiodetect i2ctransfer; do
	command -v $t >/dev/null || { echo "$t missing (pacman -S libgpiod i2c-tools)" >&2; exit 1; }
done
[ -f "$ko" ] || { echo "$ko missing; run scripts/build-debug.sh" >&2; exit 1; }
dev=/sys/bus/i2c/devices/i2c-INT3477:00
[ -e $dev ] || { echo "sensor device not present; run test-load.sh first" >&2; exit 1; }
bus=$(basename "$(readlink -f $dev/..)"); bus=${bus#i2c-}
chip=$(gpiodetect | awk '/tps68470-gpio/ {print $1; exit}')
[ -n "$chip" ] || { echo "tps68470 gpiochip not found" >&2; exit 1; }

say() { printf '\n==> %s\n' "$*"; }
bus_ok() { timeout 2 i2ctransfer -f -y "$bus" w1@0x48 0xff r1 >/dev/null 2>&1; }
rd() { timeout 2 i2ctransfer -f -y "$bus" w2@"$1" 0x30 0x0a r3 2>&1 | sed 's/Error: Sending messages failed: //' | tr '\n' ' '; }
gp=
release() { [ -n "$gp" ] && kill "$gp" 2>/dev/null; gp=; sleep 0.05; }
trap release EXIT
idle() { release; gpioset -c "$chip" -z 8="$1"; sleep 0.1; gp=$(pgrep -n -x gpioset || true); }
probe() {
	bus_ok || { echo "  !! bus i2c-$bus stopped responding at '$1'; aborting. Power off fully." >&2; exit 2; }
	printf '  %-30s 0x10: %-24s 0x36: %s\n' "$1" "$(rd 0x10)" "$(rd 0x36)"
}

mark=$(dmesg | wc -l)
[ -d /sys/module/ov8858 ] && rmmod ov8858
say "insmod debug ov8858, holding power ${hold}s on failure"
insmod "$ko" dbg_settle_ms=20 dbg_hold_s="$hold" &
loader=$!
i=0
until dmesg | tail -n +"$((mark + 1))" | grep -q 'dbg: ID read failed'; do
	i=$((i + 1)); [ $i -lt 100 ] || { echo "no hold state:"; dmesg | tail -n +"$((mark + 1))" | grep ov8858; exit 1; }
	sleep 0.1
done

say "TPS68470 registers 0x00-0x50 (read-only, during hold)"
r=0
while [ $r -le 80 ]; do
	[ $((r % 16)) = 0 ] && printf '  %02x:' $r
	v=$(timeout 2 i2ctransfer -f -y "$bus" w1@0x48 $r r1 2>/dev/null || echo XX)
	printf ' %s' "${v#0x}"
	[ $((r % 16)) = 15 ] && echo
	r=$((r + 1))
done
echo

say "chip-ID reads (expect '0x00 0x88 0x58'); levels are raw pin levels"
for s_idle in 1 0; do
	idle $s_idle
	for rst in 1 0; do
		for pd in 1 0; do
			echo $rst > $par/dbg_reset_raw
			echo $pd > $par/dbg_pwdn_raw
			sleep 0.05
			probe "s_resetn=$rst s_enable=$pd s_idle=$s_idle"
		done
	done
done
release
echo 1 > $par/dbg_reset_raw; echo 1 > $par/dbg_pwdn_raw

say "done; waiting for the driver to finish its hold and power off"
wait "$loader" || true
dmesg | tail -n +"$((mark + 1))" | grep -E 'ov8858|tps68470|designware|failed' | grep -v 'dbg:' | sed 's/^/  /'
