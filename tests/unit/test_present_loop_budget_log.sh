#!/bin/sh
# Red-before-green: budget log helper + %48 cadence documentation in RCA tools.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Synthetic log fragment matching product field names
cat >"$tmp" <<'EOF'
media: content fps=24/1 fps_src=caller_supplied lead_ms=40 resync_drop_ms=80
media: GEOM arm_rescale=1 identity_skip=0
media: av_hold_first_10s wall_s=10.0 av_hold_count=12 av_hold_wait_ms=24 tag=measured
media: fpga frame_tx ok via DDR presents=48 frames=60 ms=7
media: fpga frame_tx ok via DDR presents=96 frames=134 ms=9
media: A/V resync drop wall_s=5.0 drift_ms=120 drops=10 frames=50 presents=40
media: t frames=303 vfps=13.2 pfps=8.16 drops=131 av_drift_ms=+215 wall_s=26.0 presents=192
EOF

out=$(sh "$ROOT_DIR/tools/present_loop_budget_from_log.sh" "$tmp")
echo "$out" | grep -q 'presents_plus_48_is_log_cadence' || {
  echo "FAIL must document +48 log cadence"
  exit 1
}
echo "$out" | grep -q 'vfps=13.2' || {
  echo "FAIL must surface vfps"
  exit 1
}
echo "$out" | grep -q 'residual_frames_minus_presents_minus_drops=' || {
  echo "FAIL residual"
  exit 1
}
# residual 303-192-131 = -20
echo "$out" | grep -q 'residual_frames_minus_presents_minus_drops=-20' || {
  echo "FAIL residual arithmetic"
  exit 1
}

# Empty → 77
set +e
sh "$ROOT_DIR/tools/present_loop_budget_from_log.sh" /dev/null >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 77 ] || [ "$rc" -eq 2 ] || {
  echo "FAIL empty log want 77/2 got $rc"
  exit 1
}

# Source still has % 48 log
grep -q 'presentCount_ % 48' "$ROOT_DIR/arm/misterplexd/media_player.cpp" || {
  echo "FAIL presentCount_%48 log site moved — update RCA"
  exit 1
}
grep -q 'maxDropRun = 1' "$ROOT_DIR/host/libmisterplex/av_clock.hpp" || \
grep -q 'maxDropRun = 1' "$ROOT_DIR/host/libmisterplex/av_clock.hpp" 2>/dev/null || \
grep -n 'maxDropRun' "$ROOT_DIR/host/libmisterplex/av_clock.hpp" | head -5

grep -q 'maxDropRun' "$ROOT_DIR/host/libmisterplex/av_clock.hpp" || {
  echo "FAIL maxDropRun missing"
  exit 1
}

echo "RESULT=PASS test_present_loop_budget_log"
exit 0
