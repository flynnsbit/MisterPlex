#!/usr/bin/env bash
# Parent-run lipsync soak: concurrent ARM CPU% + HDMI A/V measure + time series.
# Does NOT cast or deploy. Device must already be playing the blip fixture.
# Capture true rc DIRECTLY on the measure step (never through a pipe).
#
# HARD EXCLUSIONS (parent fleet 2026-08-01, RBF c5382bee):
#   - Never read PLXD frames_done / presents / drops / unaccounted
#     (frames_done = vsync counter; unaccounted ≡ residual ≡ publish_misses).
#   - Never gate on companion :3005 ledger fields for lipsync.
#   - A/V GT = MS2109 /dev/video0 + ALSA only (wallclock-shared ffmpeg).
#   - Visual marker must be full-frame (240-row ceiling proven on glass).
set -euo pipefail
# Refuse accidental PLXD/ledger env that would tempt a future edit:
if [[ -n "${PLXD_SCORE:-}" || -n "${USE_PLXD_FRAMES_DONE:-}" ]]; then
  echo "UNSCORED: PLXD-based scoring is void on c5382bee (frames_done=vsync)"
  exit 77
fi
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
MIN_PAIRS="${MIN_PAIRS:-40}"
SKIP_SESSION_GATE="${SKIP_SESSION_GATE:-0}"
mkdir -p "$OUT"

if command -v fuser >/dev/null 2>&1; then
  if fuser "$VIDEO_DEV" >/dev/null 2>&1; then
    echo "WARN $VIDEO_DEV busy"
    fuser -v "$VIDEO_DEV" 2>&1 || true
  fi
fi

# Fixture contract (gen_avsync_blip.py — not guessed):
# flash_s = 2/fps @ 24.000 → 0.0833 s full-frame white every 1.0 s (duty 8.33%).
# Host-measured assets/avsync/sync_24fps_blip.mp4: duty_hot=0.0833 contrast≈233.
echo "=== FIXTURE CONTRACT ==="
echo "fixture_flash_period_s=1.0 src=caller_supplied_gen_avsync_blip"
echo "fixture_flash_duration_s=0.083333 src=caller_supplied_2_frames_at_24fps"
echo "fixture_flash_duty=0.0833 src=measured_file_and_generator"
echo "fixture_beep_ms=50 src=caller_supplied_gen_avsync_blip"
echo "fixture_fps=24.000 src=caller_supplied_ffprobe_r_frame_rate_24/1"
warm_s=$(awk -v w=20 -v f="$CAP_FPS" 'BEGIN{printf "%.3f", w/f}')
min_dur=$(awk -v w="$warm_s" -v n="$MIN_PAIRS" 'BEGIN{printf "%.3f", w+n+1.0}')
echo "warmup_s=$warm_s src=derived_20_frames_over_cap_fps"
echo "min_duration_s_for_min_pairs=$min_dur min_pairs=$MIN_PAIRS src=derived"
if awk -v d="$DUR" -v m="$min_dur" 'BEGIN{exit !(d+0 < m+0)}'; then
  echo "VERDICT=UNSCORED rc=77 reason=DURATION_TOO_SHORT_FOR_MIN_PAIRS dur=$DUR need>=$min_dur"
  exit 77
fi

echo "=== PRE-REGISTERED PREDICTIONS (publish hit/miss after) ==="
echo "P_MEDIAN: abs(median_offset_ms_raw) < 80 ms on blip @ LEAD=40 (raw_uncalibrated)"
echo "P_SLOPE:  abs(slope_ms_per_s) < 0.5 over n_pairs>=40 (no cumulative clock walk)"
echo "P_CLASS:  timing_class in STABLE|WANDER — MONOTONIC_DRIFT means rate mismatch"
echo "P_WANDER: residual_rms_ms may be elevated if judder couples into flash phase; not assumed 0"
echo "P_CPU:    arm_cpu_pct present as measured (no band claim without baseline)"
echo "P_FLASH:  n_flashes >= 40 and no_flash_class absent on recovered device"
echo "P_BEEP:   n_beeps >= 40 (audio leg)"
echo "predictions_src=caller_supplied_pre_register"

# Session gate: wall_s advancing (derivation=session clock) — not PLXD void fields.
if [[ "$SKIP_SESSION_GATE" != "1" ]]; then
  echo "=== SESSION GATE (wall_s advancing) ==="
  set +e
  bash "$ROOT/tools/avsync_wait_session.sh" >"$OUT/session_gate.txt" 2>&1
  SG_RC=$?
  set -e
  echo "session_gate true rc=$SG_RC"
  tail -n 20 "$OUT/session_gate.txt" || true
  if [[ "$SG_RC" -ne 0 ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=session_gate_failed sg_rc=$SG_RC"
    exit 77
  fi
else
  echo "session_gate=SKIPPED src=caller_supplied"
fi

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
