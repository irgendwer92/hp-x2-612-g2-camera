#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# DEVELOPER / BRING-UP TOOL, not part of the normal install.
# Read-only dump of the TPS68470 PMIC registers (I2C address 0x48 on the bus
# of i2c-INT3472:05, i2c-2 on this tablet) with the camera-relevant ones
# decoded. Only single-register reads (i2ctransfer -f, which bypasses the
# driver's claim on the address); never writes. Needs i2c-tools.
#   sudo scripts/pmic-dump.sh
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
command -v i2ctransfer >/dev/null || { echo "i2ctransfer missing (pacman -S i2c-tools)" >&2; exit 1; }
[ -e /sys/bus/i2c/devices/i2c-INT3472:05 ] || { echo "i2c-INT3472:05 not present" >&2; exit 1; }
bus=$(basename "$(readlink -f /sys/bus/i2c/devices/i2c-INT3472:05/..)"); bus=${bus#i2c-}
rd() { i2ctransfer -f -y "$bus" w1@0x48 "$1" r1 2>/dev/null || echo "XX"; }
for r in 0x0d 0x0f 0x14 0x16 0x18 0x1a 0x1c 0x1e 0x20 0x22 0x26 0x27 \
	 0x3c 0x3d 0x3e 0x3f 0x40 0x41 0x42 0x43 0x44 0x45 0x46 0x47 0x48; do
	v=$(rd $r)
	case $r in
	0x0d) n="PLLCTL (bit0 PLL on)" ;; 0x0f) n="CLKCFG1 (HCLK A/B)" ;;
	0x14) n="GPCTL0A" ;; 0x16) n="GPCTL1A (daisy chain)" ;; 0x18) n="GPCTL2A (daisy chain)" ;;
	0x1a) n="GPCTL3A (front VCM en)" ;; 0x1c) n="GPCTL4A (front AVDD en)" ;;
	0x1e) n="GPCTL5A (front reset)" ;; 0x20) n="GPCTL6A (front powerdown)" ;;
	0x22) n="SGPO (rear s_enable/s_idle/s_resetn)" ;; 0x26) n="GPDI (input levels)" ;; 0x27) n="GPDO (output levels)" ;;
	0x3c) n="VCMVAL" ;; 0x3d) n="VAUX1VAL (front core)" ;; 0x3e) n="VAUX2VAL (front I/O)" ;;
	0x3f) n="VIOVAL" ;; 0x40) n="VSIOVAL" ;; 0x41) n="VAVAL" ;; 0x42) n="VDVAL" ;;
	0x43) n="S_I2C_CTL (VSIO en)" ;; 0x44) n="VCMCTL" ;; 0x45) n="VAUX1CTL (front core en)" ;;
	0x46) n="VAUX2CTL (front I/O en)" ;; 0x47) n="VACTL" ;; 0x48) n="VDCTL" ;;
	esac
	printf '  %s = %s  %s\n' "$r" "$v" "$n"
done
