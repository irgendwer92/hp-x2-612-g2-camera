#!/bin/sh
# Front camera (IMX241, ACPI INT347F) test without touching the normal setup.
#
#   scripts/front-test.sh [build]     as user: build build/front/ipu-bridge.ko
#                                     (patches/*.patch + patches/pending/0005)
#                                     and build/front/imx241.ko
#   sudo scripts/front-test.sh arm    stage both modules and install modprobe.d
#                                     rules that use them ONLY in a boot whose
#                                     kernel command line contains hpcam_front_test
#   (reboot, add hpcam_front_test to the kernel command line for that one boot)
#   sudo scripts/front-test.sh run    in that boot: report and capture raw frames
#   sudo scripts/front-test-restore.sh  remove the rules and staged modules
#
# Why a test boot and not a module reload: ipu-bridge builds the sensor fwnode
# graph once, on the first ipu3-cio2 probe of a boot, and attaches it to the
# CIO2 device for good. A reloaded ipu-bridge finds that graph and returns
# without adding anything (ipu_bridge_init() -> ipu_bridge_check_fwnode_graph()),
# so after a normal boot no module reload can add INT347F to the graph, and
# none can take it out again once it is there. The PMIC driver is never
# reloaded either (its probe only works once per boot).
#
# Consequences for the test boot: ipu3-cio2 exposes its media graph only when
# every sensor in the fwnode graph has bound. If imx241 fails to bind, the rear
# camera is unavailable too, until the next normal boot. A boot without
# hpcam_front_test is unaffected by the installed rules.
#
# Run options (environment):
#   SIZE=2592x1944 | 1296x972   capture size (default 2592x1944)
#   EXPOSURE=<lines> AGAIN=<0-224> DGAIN=<256-4095>  sensor controls for the
#                               camera capture (default: driver defaults, i.e.
#                               exposure about 33 ms, gain 1x)
#   FRAMES=<n>                  frames per capture (default 4)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
kver=$(uname -r)
front=$repo/build/front
stage=/var/lib/hp-x2-612-g2-camera/front-test
conf=/etc/modprobe.d/hp-x2-612-g2-camera-front-test.conf
flag=hpcam_front_test

say() { printf '\n==> %s\n' "$*"; }
die() { echo "front-test.sh: error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
do_build() {
	if [ "$(id -u)" = 0 ]; then
		[ -n "${SUDO_USER:-}" ] || die "build as your user, not as root"
		echo "building as $SUDO_USER"
		exec runuser -u "$SUDO_USER" -- "$0" build
	fi

	tag=$("$here/prepare.sh" --tag "$kver")
	mkdir -p "$front/patches"
	rm -f "$front"/patches/*.patch
	for p in "$repo"/patches/*.patch "$repo"/patches/pending/0005-*.patch; do
		[ -e "$p" ] || die "missing patch $p"
		ln -s "$p" "$front/patches/$(basename "$p")"
	done
	# Reuse the pristine sources of the normal build, if present (no network).
	if [ ! -d "$front/$tag/pristine" ] && [ -d "$repo/build/$tag/pristine" ]; then
		mkdir -p "$front/$tag"
		cp -R "$repo/build/$tag/pristine" "$front/$tag/pristine"
	fi
	BUILD_ROOT=$front PATCHES_DIR=$front/patches "$here/prepare.sh" "$kver"
	cp "$repo/Kbuild" "$front/Kbuild"
	make -C "/lib/modules/$kver/build" M="$front" HPCAM_SRC="$tag/src" modules
	grep -q INT347F "$front/$tag/src/drivers/media/pci/intel/ipu-bridge.c" ||
		die "INT347F missing from the variant ipu-bridge source"
	echo
	echo "built $front/ipu-bridge.ko (with INT347F) and $front/imx241.ko"
	echo "next: sudo $0 arm"
}

# ---------------------------------------------------------------------------
do_arm() {
	[ "$(id -u)" = 0 ] || die "run as root: sudo $0 arm"
	for m in ipu-bridge imx241; do
		f=$front/$m.ko
		[ -f "$f" ] || die "$f not found; run '$0 build' as your user first"
		vm=$(modinfo -F vermagic "$f" | awk '{print $1}')
		[ "$vm" = "$kver" ] || die "$f was built for $vm, running kernel is $kver; rebuild"
	done
	modinfo -n intel_skl_int3472_tps68470 | grep -q /updates/ ||
		die "the PMIC module is not the DKMS one; install the package with patch 0004 first"

	# Stage on the root file system: /home may not be mounted when udev
	# loads the camera modules.
	mkdir -p "$stage"
	install -m644 "$front/ipu-bridge.ko" "$front/imx241.ko" "$stage/"
	deps=$(modinfo -F depends "$stage/imx241.ko" | tr , ' ')

	cat > "$conf" <<EOF
# hp-x2-612-g2-camera front camera test (scripts/front-test.sh arm).
# Inactive unless the kernel command line contains "$flag".
# Remove with: sudo $repo/scripts/front-test-restore.sh
install ipu_bridge if grep -qw $flag /proc/cmdline; then /usr/bin/insmod $stage/ipu-bridge.ko; else /usr/bin/modprobe --ignore-install ipu_bridge \$CMDLINE_OPTS; fi
install imx241 if grep -qw $flag /proc/cmdline; then /usr/bin/modprobe -a clk_tps68470 tps68470_regulator gpio_tps68470 $deps && /usr/bin/insmod $stage/imx241.ko; else /usr/bin/modprobe --ignore-install imx241 \$CMDLINE_OPTS; fi
alias acpi*:INT347F:* imx241
EOF
	echo "installed $conf, staged modules in $stage"
	cat <<EOF

Next:
  1. Reboot. In the boot menu, edit the entry once and append  $flag
     to the kernel command line (systemd-boot: 'e'; GRUB: 'e', end of the
     'linux' line, then Ctrl-X). Boots without it are not affected.
  2. In that boot: sudo $0 run
  3. Afterwards: sudo $here/front-test-restore.sh, then reboot normally.
EOF
}

# ---------------------------------------------------------------------------
srcversion_of() { modinfo -F srcversion "$1" 2>/dev/null; }

check_loaded_variant() {
	m=$1; ko=$2
	if [ ! -d "/sys/module/$m" ]; then
		echo "  $m: NOT loaded"
		return 1
	fi
	want=$(srcversion_of "$ko")
	have=$(cat "/sys/module/$m/srcversion" 2>/dev/null || true)
	if [ -n "$want" ] && [ "$want" = "$have" ]; then
		echo "  $m: test build loaded (srcversion $have)"
	else
		echo "  $m: loaded, but NOT the test build (srcversion $have, expected $want)"
		return 1
	fi
}

pipewire_active() {
	units="pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber"
	active=""
	if [ -n "${SUDO_USER:-}" ]; then
		for u in $units; do
			if systemctl --user -M "$SUDO_USER@" is-active --quiet "$u" 2>/dev/null; then
				active="$active $u"
			fi
		done
	fi
	for p in pipewire wireplumber; do
		if [ -n "${SUDO_USER:-}" ]; then
			pgrep -u "$SUDO_USER" -x "$p" >/dev/null 2>&1 && active="$active $p(process)"
		else
			pgrep -x "$p" >/dev/null 2>&1 && active="$active $p(process)"
		fi
	done
	[ -n "$active" ] && { echo "$active"; return 0; }
	return 1
}

# media-ctl entity name containing $1, from device $2
entity_name() {
	media-ctl -d "$2" -p 2>/dev/null |
		sed -n "s/^- entity [0-9]*: \\($1[^(]*\\) (.*/\\1/p" | sed 's/ *$//' | head -n1
}

# Bayer order and IPU3 fourcc for a media bus code
bayer_of() {
	case "$1" in
	SRGGB10_1X10) echo "RGGB ip3r" ;;
	SGRBG10_1X10) echo "GRBG ip3G" ;;
	SGBRG10_1X10) echo "GBRG ip3g" ;;
	SBGGR10_1X10) echo "BGGR ip3b" ;;
	*) return 1 ;;
	esac
}

preview() {
	raw=$1; png=$2; order=$3
	py=$repo/tools/lsc/.venv/bin/python
	[ -x "$py" ] || py=python3
	cmd="$py $repo/tools/raw2png.py $raw $width $height $order -o $png"
	if [ -n "${SUDO_USER:-}" ]; then
		runuser -u "$SUDO_USER" -- $cmd || echo "  (preview failed; numpy missing? see tools/lsc/README.md)"
	else
		$cmd || echo "  (preview failed; numpy missing? see tools/lsc/README.md)"
	fi
}

capture() {
	label=$1
	out=$capdir/$label.raw
	rm -f "$out"
	if ! v4l2-ctl -d "$video" \
		--set-fmt-video=width="$width",height="$height",pixelformat="$fourcc" \
		--stream-mmap --stream-skip=2 --stream-count="$frames" \
		--stream-to="$out" 2>&1 | tail -n 3 | sed 's/^/  /'; then
		echo "  capture failed"
	fi
	if [ -s "$out" ]; then
		echo "  $out: $(stat -c %s "$out") bytes"
		preview "$out" "$capdir/$label.png" "$order"
	else
		echo "  no data captured (check dmesg for CSI-2 / cio2 errors)"
	fi
}

# Swap in a rebuilt imx241.ko inside a running test boot. The camera graph
# (ipu-bridge software nodes, including INT347F) persists for the whole boot,
# so only the CIO2 driver and the sensor drivers need reloading; the PMIC
# driver is left alone.
do_reload() {
	[ "$(id -u)" = 0 ] || die "run as root: sudo $0 reload"
	grep -qw "$flag" /proc/cmdline ||
		die "only in a test boot (kernel command line with '$flag')"
	[ -f "$front/imx241.ko" ] || die "$front/imx241.ko not found; run '$0 build' as your user first"
	if active=$(pipewire_active); then
		echo "PipeWire is active:$active; stop it first" >&2
		exit 1
	fi
	install -m644 "$front/imx241.ko" "$stage/imx241.ko"

	say "reloading ipu3_cio2 and the sensor drivers"
	for m in ipu3_cio2 ov8858 dw9714 imx241; do
		if [ -d "/sys/module/$m" ]; then
			echo "  rmmod $m"
			rmmod "$m" || die "cannot unload $m"
		fi
	done
	modprobe -a $(modinfo -F depends "$stage/imx241.ko" | tr , ' ')
	insmod "$stage/imx241.ko" dyndbg=+p
	modprobe ipu3_cio2
	modprobe ov8858
	modprobe dw9714 2>/dev/null || true
	udevadm settle -t 10 || true
	sleep 1
	dmesg | tail -n 40 | grep -E 'imx241|ov8858|cio2' | sed 's/^/  /'
	echo
	echo "now run: sudo $0 run"
}

do_run() {
	[ "$(id -u)" = 0 ] || die "run as root: sudo $0 run"
	grep -qw "$flag" /proc/cmdline ||
		die "this boot was started without '$flag' on the kernel command line (see '$0 arm')"
	if active=$(pipewire_active); then
		echo "PipeWire is active:$active" >&2
		echo "stop it first (as your user):" >&2
		echo "  systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber" >&2
		exit 1
	fi

	say "modules"
	ok=1
	check_loaded_variant ipu_bridge "$stage/ipu-bridge.ko" || ok=0
	check_loaded_variant imx241 "$stage/imx241.ko" || ok=0
	for m in intel_skl_int3472_tps68470 ipu3_cio2 ov8858 dw9714 clk_tps68470 tps68470_regulator gpio_tps68470; do
		if [ -d "/sys/module/$m" ]; then echo "  $m: loaded"; else echo "  $m: NOT loaded"; fi
	done
	[ "$ok" = 1 ] || echo "  WARNING: the test modules are not (both) loaded; the install rules did not apply?"

	say "devices"
	for d in i2c-INT3472:05 i2c-INT3477:00 i2c-INT347F:00; do
		p=/sys/bus/i2c/devices/$d
		if [ -e "$p" ]; then
			drv=$(basename "$(readlink "$p/driver" 2>/dev/null)" 2>/dev/null || true)
			echo "  $d: driver=${drv:-<none>}"
		else
			echo "  $d: not present"
		fi
	done
	if [ -r /sys/kernel/debug/devices_deferred ]; then
		echo "  deferred probes:"
		sed 's/^/    /' /sys/kernel/debug/devices_deferred
	fi

	say "kernel log (filtered)"
	dmesg | grep -Ei 'imx241|INT347F|ov8858|INT3477|cio2|ipu-bridge|ipu_bridge|tps68470|xvclk' |
		tail -n 60 | sed 's/^/  /' || echo "  (no matching lines)"

	media=""
	for m in /dev/media*; do
		[ -e "$m" ] || continue
		if media-ctl -d "$m" -p 2>/dev/null | grep -q 'ipu3-cio2'; then media=$m; break; fi
	done
	if [ -z "$media" ]; then
		say "no ipu3-cio2 media device"
		echo "  ipu3-cio2 registers its media graph only after all sensors bound;"
		echo "  imx241 (or ov8858) did not bind. See the kernel log above."
		echo "  The rear camera is unavailable in this boot too; reboot normally to get it back."
		exit 1
	fi

	say "media topology: sensors ($media)"
	media-ctl -d "$media" -p 2>&1 | awk '
		/^- entity/ { show = ($0 ~ /imx241|ov8858|ipu3-csi2 [01]/) }
		show { print "  " $0 }
		/^$/ { show = 0 }'

	say "libcamera: cam -l"
	if command -v cam >/dev/null; then
		cam -l 2>&1 | sed 's/^/  /' || true
	else
		echo "  cam not installed (libcamera-tools)"
	fi

	sensor=$(entity_name imx241 "$media")
	[ -n "$sensor" ] || die "no imx241 entity in $media"
	subdev=$(media-ctl -d "$media" -e "$sensor")
	video=$(media-ctl -d "$media" -e "ipu3-cio2 1")
	size=${SIZE:-2592x1944}
	width=${size%x*}
	height=${size#*x}
	frames=${FRAMES:-4}

	say "configuring $sensor -> ipu3-csi2 1 -> ipu3-cio2 1 ($video), $size"
	media-ctl -d "$media" -l "\"$sensor\":0 -> \"ipu3-csi2 1\":0[1]"
	# The flips are off by default; the code reported for that is the native order.
	code=$(media-ctl -d "$media" --get-v4l2 "\"$sensor\":0" |
		sed -n 's/.*fmt:\([A-Z0-9_]*\)\/.*/\1/p')
	bo=$(bayer_of "$code") || die "unexpected sensor format '$code'"
	order=${bo% *}
	fourcc=${bo#* }
	media-ctl -d "$media" -V "\"$sensor\":0 [fmt:$code/$size]"
	media-ctl -d "$media" -V "\"ipu3-csi2 1\":0 [fmt:$code/$size]"
	media-ctl -d "$media" -V "\"ipu3-csi2 1\":1 [fmt:$code/$size]"
	media-ctl -d "$media" --get-v4l2 "\"$sensor\":0" | sed 's/^/  sensor: /'
	echo "  Bayer order $order, pixel format $fourcc, subdev $subdev"
	v4l2-ctl -d "$subdev" -l 2>&1 | sed 's/^/  /'

	capdir=$repo/captures/front-$(date +%Y%m%d-%H%M%S)
	mkdir -p "$capdir"
	# The PNG preview runs as the invoking user.
	[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER": "$repo/captures" "$capdir"

	say "capture 1: sensor test pattern (colour bars)"
	if v4l2-ctl -d "$subdev" -c test_pattern=2 2>/dev/null; then
		capture bars
		v4l2-ctl -d "$subdev" -c test_pattern=0
	else
		echo "  (could not set test_pattern)"
	fi

	say "capture 2: camera image"
	ctrls=""
	[ -n "${EXPOSURE:-}" ] && ctrls="${ctrls:+$ctrls,}exposure=$EXPOSURE"
	[ -n "${AGAIN:-}" ] && ctrls="${ctrls:+$ctrls,}analogue_gain=$AGAIN"
	[ -n "${DGAIN:-}" ] && ctrls="${ctrls:+$ctrls,}digital_gain=$DGAIN"
	[ -n "$ctrls" ] && v4l2-ctl -d "$subdev" -c "$ctrls"
	capture image

	if [ -n "${SUDO_USER:-}" ]; then
		chown -R "$SUDO_USER": "$capdir"
	fi

	say "kernel log during capture (filtered)"
	dmesg | grep -Ei 'imx241|cio2|csi2' | tail -n 20 | sed 's/^/  /' || true

	echo
	echo "Captures in $capdir"
	echo "Expected: bars.png shows vertical colour bars (white, yellow, cyan, green,"
	echo "magenta, red, blue, black for SMIA); image.png a recognisable (unprocessed) picture."
	echo "Done. Clean up with: sudo $here/front-test-restore.sh (then reboot normally)."
}

case "${1:-build}" in
build) do_build ;;
arm) do_arm ;;
reload) do_reload ;;
run) do_run ;;
*) echo "usage: $0 [build|arm|reload|run]" >&2; exit 1 ;;
esac
