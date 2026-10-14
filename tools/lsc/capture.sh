#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Capture raw Bayer flat-field (or dark) frames from the OV8858 rear camera of
# the HP Pro x2 612 G2 through libcamera's IPU3 pipeline, for calibrate.py.
#
# BEFORE RUNNING: stop PipeWire, cam needs exclusive access to the camera:
#     systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
# and afterwards restart it:
#     systemctl --user start pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber
#
# Flat-field target: an evenly lit, matte white sheet (or a diffuser / opal
# glass held directly in front of the lens) filling the WHOLE frame, lit by
# the illuminant you calibrate for (e.g. daylight ~5000 K), no shadows, no
# hot spots, slightly defocused so paper texture disappears. Nothing may clip:
# calibrate.py warns if pixels reach the white level. Avoid mains-flickering
# light (or keep exposure a multiple of 10 ms).
#
# Dark frames (--dark): cover the lens completely (e.g. thumb + black cloth) to
# measure the real black level; pass the directory to calibrate.py --dark.
#
# How the raw stream is obtained (libcamera v0.7.2, ipu3.cpp):
#   * StreamRole::Raw yields the CIO2 output at full sensor resolution
#     (3264x2448), pixel format SBGGR10_IPU3 (V4L2 'ip3b', 25 px / 32 bytes,
#     line stride 4224 bytes).
#   * The IPU3 pipeline rejects raw-only configurations ("Camera configuration
#     cannot support raw-only streams"), so a viewfinder stream is requested
#     too: stream0 = viewfinder (NV12, discarded), stream1 = raw.
#   * The first frames are dropped while AGC/AWB/AF settle.

set -euo pipefail

usage() {
	cat <<EOF
Usage: $0 [options]
  -o DIR      output directory (default: captures/flat-<timestamp>, or
              captures/dark-<timestamp> with --dark)
  -n N        number of raw frames to keep (default 8)
  -s N        frames to drop at the start while AE/AWB/AF settle (default 24)
  -c CAMERA   cam camera index or id (default 1; see 'cam -l')
  --dark      label the capture as dark frames (lens covered)
  -h          this help
EOF
}

OUT=""
KEEP=8
SKIP=24
CAMERA=1
KIND=flat
CAM=${CAM:-/usr/bin/cam}

while [ $# -gt 0 ]; do
	case "$1" in
	-o) OUT=$2; shift 2 ;;
	-n) KEEP=$2; shift 2 ;;
	-s) SKIP=$2; shift 2 ;;
	-c) CAMERA=$2; shift 2 ;;
	--dark) KIND=dark; shift ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

[ -x "$CAM" ] || { echo "error: $CAM not found (install libcamera-tools)" >&2; exit 1; }
[ -n "$OUT" ] || OUT="captures/$KIND-$(date +%Y%m%d-%H%M%S)"

# PipeWire / WirePlumber hold the camera; refuse to run while they are active.
busy=""
for u in pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber; do
	if systemctl --user is-active --quiet "$u" 2>/dev/null; then
		busy="$busy $u"
	fi
done
if [ -n "$busy" ]; then
	echo "error: still running:$busy" >&2
	echo "Stop them first (cam needs exclusive camera access):" >&2
	echo "    systemctl --user stop pipewire.socket pipewire-pulse.socket pipewire pipewire-pulse wireplumber" >&2
	exit 1
fi

mkdir -p "$OUT"
LOG="$OUT/cam.log"
TOTAL=$((SKIP + KEEP))

echo "Capturing $TOTAL frames (keeping the last $KEEP) to $OUT ..."
# -I prints the validated stream configuration (verifies stream1 is raw),
# --metadata prints ExposureTime/AnalogueGain/ColourTemperature per request.
"$CAM" -c "$CAMERA" -I \
	-s role=viewfinder -s role=raw \
	-C"$TOTAL" --metadata \
	-F"$OUT/frame-#.bin" 2>&1 | tee "$LOG" | grep -E '^[0-9]+: |error|fail|invalid' || true

# Viewfinder frames are not needed.
rm -f "$OUT"/frame-cam0-stream0-*.bin

if ! grep -qE '^1: 3264x2448-SBGGR10_IPU3' "$LOG"; then
	echo "warning: stream1 is not 3264x2448-SBGGR10_IPU3, check $LOG;" \
	     "pass --width/--height/--bayer-order to calibrate.py accordingly" >&2
fi

mapfile -t raws < <(ls "$OUT"/frame-cam0-stream1-*.bin 2>/dev/null | sort)
if [ "${#raws[@]}" -eq 0 ]; then
	echo "error: no raw frames captured, see $LOG" >&2
	exit 1
fi
ndrop=$(( ${#raws[@]} > KEEP ? ${#raws[@]} - KEEP : 0 ))
for ((i = 0; i < ndrop; i++)); do rm -f "${raws[$i]}"; done

kept=$(ls "$OUT"/frame-cam0-stream1-*.bin | wc -l)
size=$(stat -c %s "$(ls "$OUT"/frame-cam0-stream1-*.bin | head -1)")
echo "Kept $kept raw frame(s), $size bytes each" \
     "(expected 10340352 = 4224 x 2448 for 3264x2448 IPU3 10-bit)."

# Summarise the metadata of the last request (exposure, gain, AWB estimate).
{
	echo "# last request metadata"
	awk '/seq:/ { blk = "" } /^\t/ { blk = blk $0 "\n" } END { printf "%s", blk }' "$LOG"
} > "$OUT/metadata.txt"
grep -E 'ExposureTime|AnalogueGain|ColourTemperature|ColourGains|LensPosition' \
	"$OUT/metadata.txt" | sed 's/^\t/  /' || true
echo
echo "If ColourTemperature above looks plausible you can use it for --ct;"
echo "better: use the known colour temperature of your light source."
echo "Next: tools/lsc/.venv/bin/python tools/lsc/calibrate.py --ct 5000 $OUT"
