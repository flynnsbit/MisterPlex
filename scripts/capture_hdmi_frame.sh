#!/usr/bin/env bash
# capture_hdmi_frame.sh — canonical HDMI-to-USB grabber capture (host).
#
# DEFECTIVE RECIPE (do NOT use):
#   ffmpeg … -frames:v 1 -y out.png
# The MacroSilicon 534d:2109 needs ~11–15 warm-up frames; frame 0 is often
# uniform grey (mean_rgb≈7 std_luma=0) while the live screen is fine.
# Parent measured 2026-07-31: bare -frames:v 1 → rc=8 uniform_frame;
# select=gte(n\,20) on the SAME screen → mean≈38.67 std≈18.53 rc=0.
#
# Usage:
#   scripts/capture_hdmi_frame.sh [out.png] [device]
# Env:
#   HDMI_DEVICE   default /dev/video0
#   HDMI_WARMUP_N default 20 (1-based frame index to keep)
#   HDMI_SIZE     default 1920x1080
set -euo pipefail

OUT="${1:-build/hdmi-capture/live.png}"
DEV="${2:-${HDMI_DEVICE:-/dev/video0}}"
WARM="${HDMI_WARMUP_N:-20}"
SIZE="${HDMI_SIZE:-1920x1080}"

mkdir -p "$(dirname "$OUT")"

if [ ! -e "$DEV" ]; then
  echo "FAIL capture device missing: $DEV" >&2
  echo "true rc=2"
  exit 2
fi

# Refuse if something else holds the device (exclusive).
if command -v fuser >/dev/null 2>&1; then
  if fuser "$DEV" >/dev/null 2>&1; then
    echo "FAIL $DEV busy (fuser):" >&2
    fuser -v "$DEV" >&2 || true
    echo "true rc=16"
    exit 16
  fi
fi

set +e
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size "$SIZE" \
  -i "$DEV" -vf "select=gte(n\\,${WARM})" -frames:v 1 -y "$OUT"
rc=$?
set -e
if [ "$rc" -ne 0 ] || [ ! -s "$OUT" ]; then
  echo "FAIL ffmpeg capture rc=$rc out=$OUT" >&2
  echo "true rc=${rc:-1}"
  exit "${rc:-1}"
fi
echo "OK capture out=$OUT warm_n=$WARM dev=$DEV bytes=$(wc -c <"$OUT" | tr -d ' ')"
echo "true rc=0"
exit 0
