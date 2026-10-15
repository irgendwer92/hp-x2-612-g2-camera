#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Read-only report of the IPU3 camera configuration an HP (or other Intel IPU3)
# tablet's firmware provides: camera module names, I2C addresses, CSI-2
# lanes/ports and the PMIC type. This is what is needed to tell whether a
# model is wired like the HP Pro x2 612 G2 (see README.md, "Other models").
#
# It evaluates ACPI methods of the camera devices (_HID, _DDN, _CRS, SSDB,
# CLDB, ...) through the acpi_call kernel module. Nothing is written to the
# firmware or the hardware; acpi_call is loaded for the dump and unloaded
# again if this script loaded it.
#
# Usage (as root):  sudo scripts/acpi-camera-dump.sh [output-file]
# Needs:            acpi_call (Arch: pacman -S acpi_call, or acpi_call-dkms /
#                   acpi_call-lts for other kernels)
# Default output:   ./acpi-camera-dump.txt
set -eu

out=${1:-acpi-camera-dump.txt}
call=/proc/acpi/call

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

loaded_here=
if [ ! -e "$call" ]; then
	modprobe acpi_call 2>/dev/null || {
		echo "error: the acpi_call module is not available." >&2
		echo "On Arch: pacman -S acpi_call (or acpi_call-dkms / acpi_call-lts)" >&2
		exit 1
	}
	loaded_here=1
fi
cleanup() { [ -n "$loaded_here" ] && modprobe -r acpi_call 2>/dev/null || true; }
trap cleanup EXIT

# Evaluate one ACPI object; print its value or the ACPI error.
acpi_eval() {
	printf '%s' "$1" > "$call"
	tr -d '\0' < "$call"
}

dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || echo "?"; }

{
	echo "# acpi-camera-dump ($(date -u +%Y-%m-%dT%H:%MZ))"
	echo "vendor:  $(dmi sys_vendor)"
	echo "product: $(dmi product_name)"
	echo "board:   $(dmi board_name)"
	echo "bios:    $(dmi bios_version) ($(dmi bios_date))"
	echo "kernel:  $(uname -r)"
	echo

	echo "## Camera related ACPI devices"
	found=
	for d in /sys/bus/acpi/devices/*; do
		hid=$(cat "$d/hid" 2>/dev/null) || continue
		case $hid in
		INT3472|INT33BE|INT34[0-9A-F][0-9A-F]|OVTI*|SONY*|HIMX*) ;;
		*) continue ;;
		esac
		# INT340x/INT344x are thermal and ISH devices, not cameras.
		case $hid in INT340?|INT344?|INT345?|INT346?) continue ;; esac
		status=$(cat "$d/status" 2>/dev/null || echo "?")
		path=$(cat "$d/path" 2>/dev/null || echo "?")
		echo
		echo "### $(basename "$d")  hid=$hid  status=$status  path=$path"
		# status 0: not present / disabled by firmware; nothing to evaluate
		[ "$status" = 0 ] && continue
		found=1
		for m in _HID _DDN _CRS _DEP _PLD SSDB CLDB; do
			printf '%s = %s\n' "$m" "$(acpi_eval "$path.$m")"
		done
	done
	[ -n "$found" ] || echo "(no enabled camera devices found)"
	echo

	echo "## PCI imaging devices"
	for d in /sys/bus/pci/devices/*; do
		case $(cat "$d/class" 2>/dev/null) in
		0x0480*) ;;
		*) continue ;;
		esac
		echo "$(basename "$d") $(cat "$d/vendor"):$(cat "$d/device") class=$(cat "$d/class") driver=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"
	done
	echo

	echo "## Kernel log (camera related)"
	dmesg 2>/dev/null | grep -iE 'int3472|tps68470|ipu3|cio2|imgu|ipu-bridge|ipu_bridge|ov[0-9]{4}|imx[0-9]{3}|dw97' || echo "(nothing)"
	echo

	echo "## Loaded camera modules"
	lsmod | grep -iE 'ipu|int3472|tps68470|ov[0-9]{4}|imx[0-9]{3}|dw97|v4l2' || echo "(none)"
} > "$out"

[ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$out"
echo "wrote $out ($(wc -l < "$out") lines)"
echo "Please attach or paste it into a hardware report:"
echo "  https://github.com/irgendwer92/hp-x2-612-g2-camera/issues/new?template=hardware-report.yml"
