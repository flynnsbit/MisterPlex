#!/usr/bin/env bash
# Parent-run lipsync soak: concurrent ARM CPU% + HDMI A/V measure + time series.
# Does NOT cast or deploy. Device must already be playing the blip fixture.
# Capture true rc DIRECTLY on the measure step (never through a pipe).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/avsync_hdmi_out/lipsync_soak}"
DUR="${DURATION:-60}"
TOL="${TOL_MS:-42}"
SLOPE_TOL="${SLOPE_TOL_MS_PER_S:-0.5}"
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-hw:0,0}"
VIDEO_SIZE="${VIDEO_SIZE:-1920x1080}"
CAP_FPS="${CAP_FPS:-30}"
LABEL="${LABEL:-lipsync}"
mkdir -p "$OUT"

if command -v fuser >/dev/null 2>&1; then
  if fuser "$VIDEO_DEV" >/dev/null 2>&1; then
    echo "WARN $VIDEO_DEV busy"
    fuser -v "$VIDEO_DEV" 2>&1 || true
  fi
fi

echo "=== PRE-REGISTERED PREDICTIONS (publish hit/miss after) ==="
echo "P_MEDIAN: abs(median_offset_ms_raw) < 80 ms on soak480 blip @ LEAD=40 (raw_uncalibrated)"
echo "P_SLOPE:  abs(slope_ms_per_s) < 0.5 over n_pairs>=40 (no cumulative clock walk)"
echo "P_CLASS:  timing_class in STABLE|WANDER — MONOTONIC_DRIFT means rate mismatch"
echo "P_WANDER: residual_rms_ms may be elevated if judder couples into flash phase; not assumed 0"
echo "P_CPU:    arm_cpu_pct present as measured (no band claim without baseline)"
echo "predictions_src=caller_supplied_pre_register"

CPU_JSON="$OUT/arm_cpu.json"
# Start CPU sample first and wait briefly so the JSON exists before measure ends
# (measure reads --cpu-pct-json at report time, after capture+decode).
(
  bash "$ROOT/tools/avsync_sample_arm_cpu.sh" >"$CPU_JSON" 2>"$OUT/arm_cpu.err" \
    || echo '{"arm_cpu_pct":null,"arm_cpu_pct_src":"NO-DATA","note":"sample_script_failed"}' >"$CPU_JSON"
) &
CPU_PID=$!
# Concurrent with capture: do not block 60s; only ensure sampler is running.
sleep 0.2

set +e
python3 "$ROOT/tools/avsync_measure_hdmi.py" \
  --duration "$DUR" \
  --video-dev "$VIDEO_DEV" \
  --audio-dev "$AUDIO_DEV" \
  --video-size "$VIDEO_SIZE" \
  --cap-fps "$CAP_FPS" \
  --warmup-frames 20 \
  --tol-ms "$TOL" \
  --slope-tol-ms-per-s "$SLOPE_TOL" \
  --out "$OUT" \
  --label "$LABEL" \
  --json-out "$OUT/${LABEL}_report.json" \
  --cpu-pct-json "$CPU_JSON" \
  >"$OUT/${LABEL}_stdout.txt" 2>&1
RC=$?
set -e
echo "avsync_measure_hdmi true rc=$RC"

wait "$CPU_PID" 2>/dev/null || true
if [[ ! -s "$CPU_JSON" ]]; then
  echo '{"arm_cpu_pct":null,"arm_cpu_pct_src":"NO-DATA","note":"empty_cpu_json"}' >"$CPU_JSON"
fi

echo "=== ARM CPU (concurrent) ==="
cat "$CPU_JSON"
echo
echo "=== MEASURE TAIL ==="
tail -n 80 "$OUT/${LABEL}_stdout.txt" || true
echo "report_json=$OUT/${LABEL}_report.json"
echo "timeseries=$OUT/${LABEL}_offset_timeseries.csv"
echo "SOAK_RC=$RC"
exit "$RC"
