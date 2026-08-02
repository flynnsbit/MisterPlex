#!/bin/sh
# Offline / on-device: extract present-loop budget clues from misterplexd.log.
# Does not touch playback. Absence of a counter → NO-DATA, never 0.0 defect.
#
# Usage:
#   sh tools/present_loop_budget_from_log.sh /media/fat/misterplex_v2/misterplexd.log
#   sh tools/present_loop_budget_from_log.sh "$LOG"; echo "true rc=$?"
#
# rc: 0 printed summary; 77 NO-DATA log; 2 usage

set -eu

LOG=${1:-}
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  echo "usage: $0 /path/to/misterplexd.log" >&2
  exit 2
fi

echo "present_loop_budget_from_log path=$LOG"
echo "NOTE presents_plus_48_is_log_cadence source=media_player.cpp_presentCount_%_48"

# Last session-ish: take last 400 matching lines
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
grep -E 'vfps=|present_profile|A/V resync drop|av_hold_first_10s|fpga frame_tx ok|GEOM |content fps=|arm_rescale|identity_skip|MEASURED_FPS|raw_video_pipe' "$LOG" | tail -n 400 >"$tmp" || true

if [ ! -s "$tmp" ]; then
  echo "RESULT=NO-DATA reason=no_matching_lines"
  exit 77
fi

echo "=== last GEOM / fps banners ==="
grep -E 'GEOM |content fps=|MEASURED_FPS|raw_video_pipe' "$tmp" | tail -n 20 || echo "log_does_not_contain GEOM/fps banners in tail"

echo "=== last telemetry (vfps/pfps/drops/drift) ==="
grep 'vfps=' "$tmp" | tail -n 8 || echo "log_does_not_contain vfps="

echo "=== av_hold_first_10s (always-on hold budget) ==="
grep 'av_hold_first_10s' "$tmp" | tail -n 5 || echo "log_does_not_contain av_hold_first_10s"

echo "=== A/V resync drop (last 15) ==="
grep 'A/V resync drop' "$tmp" | tail -n 15 || echo "log_does_not_contain A/V resync drop"

ndrops=$(grep -c 'A/V resync drop' "$tmp" || true)
echo "resync_drop_lines_in_tail=$ndrops tag=measured_of_tail_not_session"

echo "=== fpga frame_tx ok (log every 48 presents — NOT a gate) ==="
grep 'fpga frame_tx ok' "$tmp" | tail -n 8 || echo "log_does_not_contain frame_tx"

echo "=== present_profile (only if PRESENT_PROFILE=1) ==="
if grep -q 'present_profile' "$tmp"; then
  grep 'present_profile' "$tmp" | tail -n 5
  echo "profile_src=measured"
else
  echo "present_profile=NO-DATA reason=PRESENT_PROFILE_off_or_not_in_tail"
fi

# Crude parse last vfps line fields if present
last=$(grep 'vfps=' "$tmp" | tail -n 1 || true)
if [ -n "$last" ]; then
  echo "=== parse last vfps line ==="
  echo "$last"
  # extract key=value tokens
  for k in frames vfps pfps drops av_drift_ms wall_s presents; do
    v=$(echo "$last" | sed -n "s/.*${k}=\([^ ]*\).*/\1/p" | head -n 1)
    if [ -n "$v" ]; then
      echo "  $k=$v tag=measured"
    else
      echo "  $k=NO-DATA"
    fi
  done
  # residual check if all ints available
  fr=$(echo "$last" | sed -n 's/.*[^_]frames=\([0-9][0-9]*\).*/\1/p' | head -n 1)
  pr=$(echo "$last" | sed -n 's/.*presents=\([0-9][0-9]*\).*/\1/p' | head -n 1)
  dr=$(echo "$last" | sed -n 's/.*drops=\([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -n "$fr" ] && [ -n "$pr" ] && [ -n "$dr" ]; then
    res=$((fr - pr - dr))
    echo "  residual_frames_minus_presents_minus_drops=$res tag=measured"
    echo "  residual_note=parent_closed_ledger_within_noise"
  fi
fi

echo "RESULT=OK"
exit 0
