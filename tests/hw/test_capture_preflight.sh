#!/usr/bin/env bash
# Capture rig preflight: enumerate the HDMI capture device, verify it is not
# busy, negotiate MJPEG 1280x720@60, grab N live frames, prove they are not
# frozen, and classify the signal as CONTENT_PRESENT / BLACK_SIGNAL / NO_SIGNAL.
#
# Conventions:
#   Exit 0 = PASS (CONTENT_PRESENT, live signal with picture)
#   Exit 1 = FAIL (black screen, no signal, frozen, busy, wrong format)
#   Exit 77 = UNSCORED (no device present — hardware simply not installed)
#
# Env overrides:
#   HDMI_DEV              preferred capture device (default: auto-select best MJPG node)
#   CAPTURE_INPUT_FORMAT  v4l2 input format to request (default: mjpeg)
#   CAPTURE_SIZE          resolution to request (default: 1280x720)
#   CAPTURE_FPS           frame rate to request (default: 60)
#   CAPTURE_FRAMES        frames to grab for liveness check (default: 3)
#   CAPTURE_OUT_DIR       output dir for captured frames + report (default: build/capture_preflight)
#   CAPTURE_EXPECT        expected result: pass | fail | skip (for red-check demos)
#   CAPTURE_SOURCE        v4l2 | synthetic | file (default: v4l2; use synthetic for unit tests)
#   CAPTURE_SYNTHETIC_CASE  content | black | no_signal | stale
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/scripts/capture_preflight.py"

DEV="${HDMI_DEV:-}"
CAP_FMT="${CAPTURE_INPUT_FORMAT:-mjpeg}"
CAP_SIZE="${CAPTURE_SIZE:-1280x720}"
CAP_FPS="${CAPTURE_FPS:-60}"
CAP_FRAMES="${CAPTURE_FRAMES:-3}"
CAP_OUT="${CAPTURE_OUT_DIR:-$ROOT/build/capture_preflight}"
EXPECT="${CAPTURE_EXPECT:-pass}"
SOURCE="${CAPTURE_SOURCE:-v4l2}"
SYNTHETIC_CASE="${CAPTURE_SYNTHETIC_CASE:-content}"

echo "test_capture_preflight: BEGIN"
echo "Scope: 1 HDMI capture rig probe (device=${DEV:-auto}, format=$CAP_FMT $CAP_SIZE@${CAP_FPS}fps, frames=$CAP_FRAMES)"

ARGS=(
  --source "$SOURCE"
  --input-format "$CAP_FMT"
  --video-size "$CAP_SIZE"
  --framerate "$CAP_FPS"
  --frames "$CAP_FRAMES"
  --out-dir "$CAP_OUT"
)
[[ -n "$DEV" ]] && ARGS+=(--device "$DEV")
[[ "$SOURCE" == "synthetic" ]] && ARGS+=(--synthetic-case "$CAPTURE_SYNTHETIC_CASE")

set +e
python3 "$TOOL" "${ARGS[@]}"
RC=$?
set -e

case "$EXPECT:$RC" in
  pass:0)
    echo "test_capture_preflight: PASS signal=CONTENT_PRESENT"
    ;;
  pass:77)
    echo "test_capture_preflight: SKIP (no capture device present) rc=77"
    exit 77
    ;;
  pass:1)
    echo "FAIL: expected CONTENT_PRESENT but got a non-pass result (rc=$RC)" >&2
    exit 1
    ;;
  fail:1)
    echo "test_capture_preflight: red-check PASS (expected failure, got rc=$RC)"
    ;;
  fail:0)
    echo "FAIL: CAPTURE_EXPECT=fail but preflight passed (rc=0); red specimen did not go red" >&2
    exit 1
    ;;
  skip:77)
    echo "test_capture_preflight: skip-check PASS (expected 77, got rc=77)"
    ;;
  skip:*)
    echo "FAIL: CAPTURE_EXPECT=skip but got rc=$RC (expected 77)" >&2
    exit 1
    ;;
  *)
    echo "FAIL: unexpected rc=$RC for CAPTURE_EXPECT=$EXPECT" >&2
    exit 1
    ;;
esac
