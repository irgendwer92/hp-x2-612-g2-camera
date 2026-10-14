#!/bin/sh
# Bring-up experiment: with the sensor held powered by the diagnostic ov8858
# build, drive the unused TPS68470 GPIOs (0-6) high, all at once and then one
# by one, and after each step read the OV8858 chip-ID register (0x300a, expect
# 00 88 58) at 0x10 and 0x36. Also probes the module EEPROM at 0x50 to tell
# "module unpowered" apart from "sensor held in reset/powerdown".
# GPIOs 7/9 (s_enable/s_resetn) are owned by the driver and left alone.
# Only targeted reads: a blind i2cdetect scan wedged this bus once.
# Needs: libgpiod (v2), i2c-tools; test-load.sh and build-debug.sh done first.
#   sudo scripts/debug-gpio-sweep.sh
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
ko=$repo/build/debug/ov8858.ko
hold=90

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
rd() { # addr reg_hi reg_lo nbytes
	timeout 2 i2ctransfer -f -y "$bus" w2@"$1" "$2" "$3" r"$4" 2>&1 | tr '\n' ' '
}
# TPS68470 REVID register (0xff) doubles as a bus-health check: if the PMIC no
# longer answers, the bus is wedged; stop instead of piling up timeouts.
bus_ok() {
	timeout 2 i2ctransfer -f -y "$bus" w1@0x48 0xff r1 >/dev/null 2>&1
}
probe() {
	bus_ok || { echo "  !! bus i2c-$bus stopped responding before step '$1'; aborting." >&2
		echo "  !! Power the machine off completely to reset the bus and PMIC." >&2; exit 2; }
	printf '  %-14s 0x10: %-28s 0x36: %-28s eeprom 0x50: %s\n' "$1" \
		"$(rd 0x10 0x30 0x0a 3)" "$(rd 0x36 0x30 0x0a 3)" \
		"$(timeout 2 i2ctransfer -f -y "$bus" w1@0x50 0x00 r4 2>&1 | tr '\n' ' ')"
}
release() { [ -n "${gp:-}" ] && kill "$gp" 2>/dev/null; gp=; sleep 0.05; }
trap release EXIT
hi() { # drive the given lines high until release(); gpioset -z daemonizes
	gpioset -c "$chip" -z "$@"; sleep 0.1; gp=$(pgrep -n -x gpioset || true)
}

mark=$(dmesg | wc -l)
[ -d /sys/module/ov8858 ] && rmmod ov8858
say "insmod debug ov8858, holding power ${hold}s on failure (bus i2c-$bus, $chip)"
insmod "$ko" dbg_settle_ms=20 dbg_hold_s="$hold" &
loader=$!
i=0
until dmesg | tail -n +"$((mark + 1))" | grep -q 'dbg: ID read failed'; do
	i=$((i + 1)); [ $i -lt 100 ] || { echo "sensor did not reach hold state:"; dmesg | tail -n +"$((mark + 1))" | grep ov8858; exit 1; }
	sleep 0.1
done

say "chip-ID reads (expect '0x00 0x88 0x58')"
probe "baseline"
hi 0=1 1=1 2=1 3=1 4=1 5=1 6=1; probe "0-6 all high"; release
for n in 0 1 2 3 4 5 6; do
	hi $n=1; probe "gpio $n high"; release
done
say "gpio line states now"
gpioinfo -c "$chip" 2>&1 | sed 's/^/  /'

say "done; waiting for the driver to finish its hold and power off"
wait "$loader" || true
