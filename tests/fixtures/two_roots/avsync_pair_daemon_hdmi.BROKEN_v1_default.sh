#!/usr/bin/env bash
# Pair daemon 1 Hz telemetry with ONE w-avsync HDMI lipsync window.
#
# Does NOT rebuild tools/avsync_measure_hdmi.py. Wraps:
#   tools/avsync_lipsync_soak.sh  (HDMI + optional ARM CPU%)
#   concurrent ssh tail of misterplexd.log → local daemon_window.log
#   tools/correlate_daemon_hdmi_window.py (post)
#
# Parent owns device. Agent never runs this against lab hardware in-lane.
#
# Usage (device already casting soak/blip fixture, grabber free):
#   OUT=$PWD/.agent-work/w-geom/pair_$(date +%Y%m%dT%H%M%S) \
#     DURATION=60 TOL_MS=42 \
#     bash tools/avsync_pair_daemon_hdmi.sh
#   echo "true rc=$?"
#
# Env:
#   OUT DURATION TOL_MS MIN_PAIRS MARKER_PERIOD_S LABEL
#   MISTER_HOST MISTER_PASS MISTER_USER
#   DAEMON_LOG_REMOTE  default /media/fat/misterplex/misterplexd.log
#   SKIP_SESSION_GATE=1 to skip wait_session
#   PRESENT_PROFILE already on device if you want present_profile lines (optional)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/.agent-work/w-geom/pair_daemon_hdmi}"
DUR="${DURATION:-60}"
TOL="${TOL_MS:-42}"
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
LOG_REMOTE="${DAEMON_LOG_REMOTE:-/media/fat/misterplex/misterplexd.log}"
LABEL="${LABEL:-pair}"
mkdir -p "$OUT"

echo "=== avsync_pair_daemon_hdmi ==="
echo "out=$OUT duration=$DUR host=$HOST log_remote=$LOG_REMOTE"
echo "note=does_not_rebuild_avsync_measure_hdmi; wraps lipsync_soak + daemon tail"
echo "PRE_REG_MECH=UNDERPRODUCE_THEN_DROP primary; PUBLISH_INTERVAL_JITTER secondary"
echo "PRE_REG_FILE=$ROOT/.agent-work/w-geom/P480_THROUGHPUT_WANDER_PREREG.md"

# Mark host window (ISO + mono) BEFORE anything else.
date -Is | tee "$OUT/window_host_start.txt"
date +%s.%N >"$OUT/window_mono_start.txt"

# Concurrent daemon log tail (parent network). Fail soft → NO-DATA correlator.
DAEMON_RAW="$OUT/daemon_window.raw.log"
DAEMON_FILT="$OUT/daemon_window.log"
: >"$DAEMON_RAW"
: >"$DAEMON_FILT"
TAIL_PID=""
if command -v sshpass >/dev/null 2>&1; then
  set +e
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "${USER}@${HOST}" \
    "test -f '$LOG_REMOTE' && tail -n 0 -F '$LOG_REMOTE' || \
     (test -f /media/fat/misterplex_v2/misterplexd.log && tail -n 0 -F /media/fat/misterplex_v2/misterplexd.log) || \
     (test -f /tmp/misterplexd.log && tail -n 0 -F /tmp/misterplexd.log)" \
    >"$DAEMON_RAW" 2>"$OUT/daemon_tail.err" &
  TAIL_PID=$!
  set -e
  echo "daemon_tail_pid=$TAIL_PID src=ssh_tail_F"
else
  echo "daemon_tail=NO-DATA reason=no_sshpass" | tee "$OUT/daemon_tail.err"
fi

cleanup() {
  if [[ -n "${TAIL_PID}" ]]; then
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Filter interesting lines as they arrive (also keep raw).
(
  # slight delay so soak starts first
  sleep 0.3
  if [[ -n "${TAIL_PID}" ]]; then
    # shellcheck disable=SC2002
    tail -n +1 -F "$DAEMON_RAW" 2>/dev/null | \
      grep -E --line-buffered \
      'media: (frames=|A/V resync drop|present_profile|publish_interval|publish_miss|MEASURED_DELIVERY|PIPE_DESYNC)' \
      >>"$DAEMON_FILT" || true
  fi
) &
FILT_PID=$!

# ONE existing instrument window (w-avsync owned).
set +e
OUT="$OUT" DURATION="$DUR" TOL_MS="$TOL" LABEL="$LABEL" \
  MIN_PAIRS="${MIN_PAIRS:-15}" \
  MARKER_PERIOD_S="${MARKER_PERIOD_S:-1.0}" \
  SKIP_SESSION_GATE="${SKIP_SESSION_GATE:-0}" \
  bash "$ROOT/tools/avsync_lipsync_soak.sh"
SOAK_RC=$?
set -e
echo "avsync_lipsync_soak true rc=$SOAK_RC"

date -Is | tee "$OUT/window_host_end.txt"
date +%s.%N >"$OUT/window_mono_end.txt"

# Stop tails
if [[ -n "${TAIL_PID}" ]]; then
  kill "$TAIL_PID" 2>/dev/null || true
  wait "$TAIL_PID" 2>/dev/null || true
  TAIL_PID=""
fi
kill "$FILT_PID" 2>/dev/null || true
wait "$FILT_PID" 2>/dev/null || true
trap - EXIT

# If filter empty but raw has media lines, filter offline.
if [[ ! -s "$DAEMON_FILT" && -s "$DAEMON_RAW" ]]; then
  grep -E 'media: (frames=|A/V resync drop|present_profile|publish_interval|publish_miss|MEASURED_DELIVERY|PIPE_DESYNC)' \
    "$DAEMON_RAW" >"$DAEMON_FILT" || true
fi

REPORT_JSON=""
for c in "$OUT/${LABEL}_report.json" "$OUT/lipsync_report.json"; do
  if [[ -f "$c" ]]; then REPORT_JSON="$c"; break; fi
done

set +e
python3 "$ROOT/tools/correlate_daemon_hdmi_window.py" \
  --daemon-log "$DAEMON_FILT" \
  --hdmi-report "${REPORT_JSON:-}" \
  --hdmi-stdout "$OUT/${LABEL}_stdout.txt" \
  --out-dir "$OUT" \
  --soak-rc "$SOAK_RC"
CORR_RC=$?
set -e
echo "correlate_daemon_hdmi_window true rc=$CORR_RC"

echo "=== PAIR ARTIFACTS ==="
echo "daemon_window=$DAEMON_FILT"
echo "daemon_raw=$DAEMON_RAW"
echo "hdmi_report=${REPORT_JSON:-NO-DATA}"
echo "corr_json=$OUT/pair_correlation.json"
echo "corr_txt=$OUT/pair_correlation.txt"
echo "LOOK_AT: timing_class residual_rms_ms detrended_max_abs_ms | daemon vfps pfps drops av_display_offset_ms publish_misses"
echo "PAIR_SOAK_RC=$SOAK_RC PAIR_CORR_RC=$CORR_RC"
# Prefer soak rc for overall (instrument truth); correlator 77 = NO-DATA daemon side.
if [[ "$SOAK_RC" -ne 0 ]]; then
  exit "$SOAK_RC"
fi
exit "$CORR_RC"
