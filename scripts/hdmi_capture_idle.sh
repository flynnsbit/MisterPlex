#!/usr/bin/env bash
# hdmi_capture_idle.sh — single blessed host-side HDMI frame grab for promotion.
#
# HARD RULE (parent 2026-07-31, MacroSilicon 534d:2109 /dev/video0):
#   ffmpeg -frames:v 1  → often uniform grey mean≈7 std=0 (GRABBER_NOT_READY)
#   select=gte(n,WARMUP) with WARMUP≥20 → real idle (chevron mean≈38–39)
# A correctness precondition that lives only in a human's memory is not a
# precondition. This script is the only supported one-liner for idle stills.
#
# Usage:
#   scripts/hdmi_capture_idle.sh [OUT.png]
#   HDMI_DEV=/dev/video0 HDMI_WARMUP_FRAMES=20 scripts/hdmi_capture_idle.sh
#
# Exit:
#   0  wrote OUT.png
#   8  capture failed / device busy / missing ffmpeg
#   9  bad args

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-${HDMI_CAPTURE_OUT:-$ROOT/build/pair-visual/idle.png}}"
DEV="${HDMI_DEV:-/dev/video0}"
# Parent proved n>=20 is enough; motion instrument default skip=15; hw_visual=60.
# Prefer the measured minimum that fixed the false RED, overridable.
WARMUP="${HDMI_WARMUP_FRAMES:-20}"
SIZE="${HDMI_SIZE:-1920x1080}"
FMT="${HDMI_INPUT_FORMAT:-mjpeg}"
ATTEMPTS="${HDMI_CAPTURE_ATTEMPTS:-2}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "CAPTURE_FAIL ffmpeg not on PATH"
  echo "true rc=8"
  exit 8
fi

if [ ! -e "$DEV" ]; then
  echo "CAPTURE_FAIL device missing path=$DEV"
  echo "true rc=8"
  exit 8
fi

# Device busy is a real lab failure mode (OBS / xdg-open holding /dev/video0).
if command -v fuser >/dev/null 2>&1; then
  if fuser "$DEV" >/dev/null 2>&1; then
    echo "CAPTURE_FAIL device busy path=$DEV (fuser reports holders — close OBS/preview)"
    fuser -v "$DEV" 2>&1 | sed 's/^/  /' || true
    echo "true rc=8"
    exit 8
  fi
fi

mkdir -p "$(dirname "$OUT")"
echo "hdmi_capture_idle dev=$DEV warmup_frames=$WARMUP size=$SIZE out=$OUT attempts=$ATTEMPTS"

attempt=1
crc=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  # Discard first WARMUP frames inside the filter graph, then emit one PNG.
  # -update 1: single-image output without image2 sequence naming.
  set +e
  ffmpeg -hide_banner -loglevel error -y \
    -f v4l2 -input_format "$FMT" -video_size "$SIZE" \
    -i "$DEV" \
    -vf "select=gte(n\\,${WARMUP})" \
    -frames:v 1 -update 1 \
    "$OUT"
  crc=$?
  set -e
  echo "  attempt=$attempt ffmpeg true rc=$crc"
  if [ "$crc" -eq 0 ] && [ -f "$OUT" ] && [ -s "$OUT" ]; then
    echo "CAPTURE_OK path=$OUT warmup_frames=$WARMUP"
    echo "true rc=0"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 0.5
done

echo "CAPTURE_FAIL after ${ATTEMPTS} attempts out=$OUT"
echo "true rc=8"
exit 8
