#!/usr/bin/env bash
# Hardware visual decode regression: deploy/verify Plex, push a known 624x480
# Baseline/CAVLC IDR, capture the real HDMI output, and compare against a
# checked-in 640x480 golden with quantified errors + diff artifact.
#
# This is a scheduled-token test. It does not build Quartus and only deploys an
# RBF when VISUAL_RBF (or the first positional arg) is supplied.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${VISUAL_OUT:-$ROOT/build/hw_visual}"
DEV="${HDMI_DEV:-/dev/video4}"
CAP_FMT="${VISUAL_CAPTURE_FORMAT:-mjpeg}"
CAP_SIZE="${VISUAL_CAPTURE_SIZE:-1280x720}"
CAP_FPS="${VISUAL_CAPTURE_FPS:-60}"
CAP_ATTEMPTS="${VISUAL_CAPTURE_ATTEMPTS:-5}"
VIDEO_MODE="${VISUAL_VIDEO_MODE:-0}"  # MiSTer preset 0 = 1280x720@60
RBF="${VISUAL_RBF:-${1:-}}"
EXPECT="${VISUAL_EXPECT:-pass}"   # pass | fail (fail means known-bad RBF must mismatch golden)
BITSTREAM="${VISUAL_BITSTREAM:-$ROOT/tests/fixtures/hw_visual/plex_visual_624x480_1f.264}"
GOLDEN="${VISUAL_GOLDEN:-$ROOT/tests/fixtures/hw_visual/plex_visual_640x480_golden.png}"
TOOL="$ROOT/scripts/hw_visual_compare.py"

mkdir -p "$OUT"

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

ssh_m() {
  "${SSH[@]}" "$@"
}

restore_mode() {
  "${SSH[@]}" "printf '%s\n' 'video_mode 5' > /dev/MiSTer_cmd" >/dev/null 2>&1 || true
}
trap restore_mode EXIT

echo "=== hw visual geometry ==="
python3 "$TOOL" geometry | tee "$OUT/geometry.json"

if [[ -n "$RBF" ]]; then
  echo "=== deploy scheduled RBF once: $RBF ==="
  MISTER_HOST="$HOST" MISTER_PASS="$PASS" DEPLOY_LOAD=menu DEPLOY_RECOVER=reboot \
    "$ROOT/scripts/deploy_plex_core.sh" "$RBF"
else
  echo "=== no VISUAL_RBF supplied; verifying existing Plex core ==="
  ssh_m "ps | grep -q '[P]lex.rbf'"
fi

capture() {
  python3 "$TOOL" capture --device "$DEV" --input-format "$CAP_FMT" \
    --video-size "$CAP_SIZE" --framerate "$CAP_FPS" --attempts "$CAP_ATTEMPTS" "$@"
}

echo "=== set HDMI mode preset $VIDEO_MODE for capture ($CAP_FMT $CAP_SIZE@$CAP_FPS) ==="
ssh_m "printf '%s\n' 'video_mode $VIDEO_MODE' > /dev/MiSTer_cmd"
sleep 3

echo "=== capture previous condition for stale-capture rejection ==="
capture --out "$OUT/previous.png"

echo "=== push checked-in Baseline/CAVLC visual bitstream ==="
"${SCP[@]}" "$BITSTREAM" "$USER@$HOST:/media/fat/plex_visual_624x480_1f.264"
ssh_m '/media/fat/misterplex/bin/push_frame --index 3 /media/fat/plex_visual_624x480_1f.264' \
  | tee "$OUT/push.txt"
sleep 1

echo "=== status telemetry (off-screen decoder debug state) ==="
ssh_m '/media/fat/misterplex/bin/push_frame --status' | tee "$OUT/status.txt"

echo "=== repeated static captures for measured noise floor ==="
for i in 0 1 2 3 4; do
  capture --out "$OUT/cap_${i}.png"
  sleep 0.2
done
python3 "$TOOL" noise \
  --frames "$OUT/cap_0.png" "$OUT/cap_1.png" "$OUT/cap_2.png" "$OUT/cap_3.png" "$OUT/cap_4.png" \
  --out "$OUT/noise.json" | tee "$OUT/noise.txt"

echo "=== compare capture against checked-in golden ==="
set +e
python3 "$TOOL" compare \
  --golden "$GOLDEN" \
  --previous "$OUT/previous.png" \
  --capture "$OUT/cap_4.png" \
  --noise-report "$OUT/noise.json" \
  --report "$OUT/compare.json" \
  --diff "$OUT/diff.png" | tee "$OUT/compare.txt"
compare_rc=${PIPESTATUS[0]}
set -e
case "$EXPECT:$compare_rc" in
  pass:0)
    echo "VISUAL_EXPECT=pass: green compare accepted"
    ;;
  pass:1)
    echo "FAIL: visual mismatch against golden (diff=$OUT/diff.png)" >&2
    exit 1
    ;;
  fail:1)
    echo "VISUAL_EXPECT=fail: known-bad core went red as expected (diff=$OUT/diff.png)"
    ;;
  fail:0)
    echo "FAIL: VISUAL_EXPECT=fail but capture matched golden; red specimen did not go red" >&2
    exit 1
    ;;
  *:3|*:4|*:5|*:6)
    echo "FAIL: capture integrity error rc=$compare_rc (stale/corrupt/absent/busy), not a core result" >&2
    exit "$compare_rc"
    ;;
  *)
    echo "FAIL: comparator error rc=$compare_rc" >&2
    exit "$compare_rc"
    ;;
esac

if [[ "${VISUAL_FAULT_DEMO:-0}" == "1" ]]; then
  echo "=== red-path demonstration: deliberately corrupt one active captured pixel ==="
  python3 - "$OUT/cap_4.png" "$OUT/cap_bad.png" <<'PY'
from pathlib import Path
import sys
import numpy as np
from PIL import Image
src, dst = map(Path, sys.argv[1:])
im = np.array(Image.open(src).convert("RGB"), dtype=np.uint8)
im[20, 20, 1] = (int(im[20, 20, 1]) + 64) & 0xFF
Image.fromarray(im, "RGB").save(dst)
PY
  set +e
  python3 "$TOOL" compare \
    --golden "$GOLDEN" \
    --capture "$OUT/cap_bad.png" \
    --noise-report "$OUT/noise.json" \
    --report "$OUT/compare_bad_expected_fail.json" \
    --diff "$OUT/diff_bad_expected_fail.png" | tee "$OUT/compare_bad_expected_fail.txt"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL: VISUAL_FAULT_DEMO did not go red" >&2
    exit 1
  fi
  echo "VISUAL_FAULT_DEMO: expected red path returned rc=$rc"
fi

echo "test_f3_visual_golden: OK artifacts=$OUT"
