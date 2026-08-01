#!/usr/bin/env bash
# Long-duration HDMI lipsync soak (drift power + slope score).
# Parent-run only. Does NOT cast/deploy. Device must already play rk=27-class
# fixture (flash+beep every MARKER_PERIOD_S, design offset 0).
#
# Does NOT use av_drift_ms (servo deadband). GT = MS2109 v4l2+ALSA only.
# Do NOT loop a short asset — seek/loop resets presentCount_/droppedFrames_
# (media_player.cpp stream restart). rk=27 is 1200 s continuous.
#
# Capture rc DIRECTLY (never through a pipe).
set -euo pipefail
if [[ -n "${PLXD_SCORE:-}" || -n "${USE_PLXD_FRAMES_DONE:-}" ]]; then
  echo "UNSCORED: PLXD-based scoring is void"
  exit 77
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/avsync_hdmi_out/long_soak}"
# 15 min default; rk=27 supports up to 1200 s. Prefer one continuous play.
DUR="${DURATION:-900}"
MARKER_PERIOD_S="${MARKER_PERIOD_S:-2.0}"
# residual RMS from parent 60 s 480p pilot (~16 ms) — override after pilot.
SIGMA_RES_MS="${SIGMA_RES_MS:-16.0}"
SIGMA_SRC="${SIGMA_SRC:-DEFAULT_ASSUMED_parent_480p_pilot}"
WARMUP_S="${WARMUP_S:-5.0}"
# Expected pairs ≈ floor((DUR-WARMUP)/period)+1; require most of them.
MIN_PAIRS="${MIN_PAIRS:-}"
TOL_MS="${TOL_MS:-200}"   # forensic only; --no-absolute-score skips abs gate
SLOPE_TOL="${SLOPE_TOL_MS_PER_S:-}"  # default: set from δ_min after power calc
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-hw:0,0}"
VIDEO_SIZE="${VIDEO_SIZE:-1920x1080}"
CAP_FPS="${CAP_FPS:-30}"
LABEL="${LABEL:-longsoak}"
WARMUP_FRAMES="${WARMUP_FRAMES:-20}"
SKIP_SESSION_GATE="${SKIP_SESSION_GATE:-0}"
DECODE_SRC="${DECODE_SRC:-caller_supplied}"
mkdir -p "$OUT"

echo "=== avsync_long_soak ==="
echo "duration_s=$DUR src=caller_supplied"
echo "marker_period_s=$MARKER_PERIOD_S src=caller_supplied"
echo "fixture_note=rk27_GlassAV_period_2.000_design_offset_0 src=caller_supplied"
echo "sign: offset_ms=(t_beep-t_flash)*1000; positive=audio LATE"
echo "NOT_USED=av_drift_ms (servo deadband av_clock.hpp)"

if command -v fuser >/dev/null 2>&1; then
  if fuser "$VIDEO_DEV" >/dev/null 2>&1; then
    echo "VERDICT=UNSCORED rc=77 reason=VIDEO_BUSY dev=$VIDEO_DEV"
    fuser -v "$VIDEO_DEV" 2>&1 || true
    exit 77
  fi
fi

# --- Drift power (pre-register δ_min before measure) ---
echo "=== DRIFT POWER (pre-measure) ==="
set +e
python3 "$ROOT/tools/avsync_drift_power.py" \
  --duration-s "$DUR" \
  --marker-period-s "$MARKER_PERIOD_S" \
  --sigma-res-ms "$SIGMA_RES_MS" \
  --sigma-src "$SIGMA_SRC" \
  --warmup-s "$WARMUP_S" \
  >"$OUT/drift_power.txt" 2>&1
PWR_RC=$?
set -e
echo "drift_power true rc=$PWR_RC"
cat "$OUT/drift_power.txt"
if [[ "$PWR_RC" -ne 0 ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=drift_power_failed pwr_rc=$PWR_RC"
  exit 77
fi

DMIN=$(awk -F= '/^min_detectable_slope_ms_per_s=/{print $2}' "$OUT/drift_power.txt" | awk '{print $1}')
N_EXP=$(awk -F= '/^n_pairs_expected=/{print $2}' "$OUT/drift_power.txt" | awk '{print $1}')
if [[ -z "${MIN_PAIRS}" ]]; then
  # Require ≥80% of expected pairs
  MIN_PAIRS=$(awk -v n="$N_EXP" 'BEGIN{v=int(0.8*n+0.5); if(v<20)v=20; print v}')
fi
if [[ -z "${SLOPE_TOL}" ]]; then
  # Gate slightly above δ_min so null-at-80%power is PASS, not knife-edge
  SLOPE_TOL=$(awk -v d="$DMIN" 'BEGIN{if(d+0<=0){print 0.05; exit} printf "%.6f", d*1.15}')
fi
echo "min_pairs=$MIN_PAIRS src=derived_or_caller"
echo "slope_tol_ms_per_s=$SLOPE_TOL src=derived_1.15x_dmin_or_caller"
echo "min_detectable_slope_ms_per_s=$DMIN src=derived"
echo "=== PRE-REGISTERED (publish hit/miss after) ==="
echo "P_N: n_pairs >= $MIN_PAIRS (expect ~$N_EXP @ period=$MARKER_PERIOD_S)"
echo "P_SLOPE_NULL: |slope| < $DMIN ms/s → cannot reject zero drift @80% power (NOT proof of perfect sync)"
echo "P_SLOPE_FAIL: |slope| > $SLOPE_TOL → DRIFT_FAIL"
echo "P_ABS: median printed tag=raw_uncalibrated; no_absolute_score=1 (w-instr owns cal)"
echo "P_NOT_AV_DRIFT: never read av_drift_ms"
echo "predictions_src=caller_supplied_pre_register"

if [[ "$SKIP_SESSION_GATE" != "1" ]]; then
  echo "=== SESSION GATE ==="
  set +e
  bash "$ROOT/tools/avsync_wait_session.sh" >"$OUT/session_gate.txt" 2>&1
  SG_RC=$?
  set -e
  echo "session_gate true rc=$SG_RC"
  tail -n 15 "$OUT/session_gate.txt" || true
  if [[ "$SG_RC" -ne 0 ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=session_gate_failed sg_rc=$SG_RC"
    exit 77
  fi
else
  echo "session_gate=SKIPPED src=caller_supplied"
fi

ART_JSON="$OUT/artifacts.json"
CPU_JSON="$OUT/arm_cpu.json"
set +e
bash "$ROOT/tools/avsync_stamp_artifacts.sh" >"$ART_JSON" 2>"$OUT/artifacts.err"
ART_RC=$?
set -e
echo "artifacts_stamp true rc=$ART_RC"
if [[ ! -s "$ART_JSON" ]]; then
  echo '{"rbf_md5":"NO-DATA","daemon_md5":"NO-DATA","artifact_pair":"NO-DATA","artifacts_src":"NO-DATA"}' >"$ART_JSON"
fi
cat "$ART_JSON"
echo

(
  bash "$ROOT/tools/avsync_sample_arm_cpu.sh" >"$CPU_JSON" 2>"$OUT/arm_cpu.err" \
    || echo '{"arm_cpu_pct":null,"arm_cpu_pct_src":"NO-DATA","note":"sample_script_failed"}' >"$CPU_JSON"
) &
CPU_PID=$!
sleep 0.2

set +e
python3 "$ROOT/tools/avsync_measure_hdmi.py" \
  --duration "$DUR" \
  --video-dev "$VIDEO_DEV" \
  --audio-dev "$AUDIO_DEV" \
  --video-size "$VIDEO_SIZE" \
  --cap-fps "$CAP_FPS" \
  --warmup-frames "$WARMUP_FRAMES" \
  --min-pairs "$MIN_PAIRS" \
  --marker-period-s "$MARKER_PERIOD_S" \
  --tol-ms "$TOL_MS" \
  --slope-tol-ms-per-s "$SLOPE_TOL" \
  --no-absolute-score \
  --out "$OUT" \
  --label "$LABEL" \
  --json-out "$OUT/${LABEL}_report.json" \
  --cpu-pct-json "$CPU_JSON" \
  --artifacts-json "$ART_JSON" \
  --decode-src "$DECODE_SRC" \
  >"$OUT/${LABEL}_stdout.txt" 2>&1
RC=$?
set -e
echo "avsync_measure_hdmi true rc=$RC"

grep -E '^(SCORE |VERDICT=|slope_ms_per_s|n_pairs=|n_flashes=|n_beeps=|timing_class=|residual_rms|marker_period|no_absolute|artifact_pair=|rbf_md5=|daemon_md5=)' \
  "$OUT/${LABEL}_stdout.txt" || true

wait "$CPU_PID" 2>/dev/null || true
[[ -s "$CPU_JSON" ]] || echo '{"arm_cpu_pct":null,"arm_cpu_pct_src":"NO-DATA"}' >"$CPU_JSON"

# Post: compare measured slope to δ_min
SLOPE_MEAS=$(awk -F= '/^slope_ms_per_s=/{print $2; exit}' "$OUT/${LABEL}_stdout.txt" | awk '{print $1}')
if [[ -z "$SLOPE_MEAS" ]]; then
  SLOPE_MEAS=$(awk -F= '/^slope_ms_per_s_corrected=/{print $2; exit}' "$OUT/${LABEL}_stdout.txt" | awk '{print $1}')
fi
echo "=== DRIFT POWER POST ==="
echo "min_detectable_slope_ms_per_s=$DMIN src=derived"
echo "measured_slope_ms_per_s=${SLOPE_MEAS:-NO-DATA} src=measured_or_NO-DATA"
if [[ -n "${SLOPE_MEAS:-}" && -n "${DMIN:-}" ]]; then
  awk -v s="$SLOPE_MEAS" -v d="$DMIN" 'BEGIN{
    as=s; if(as<0)as=-as;
    if(as < d+0) print "drift_null_at_80pct_power=1 src=derived note=cannot_reject_zero_drift";
    else print "drift_null_at_80pct_power=0 src=derived note=slope_exceeds_dmin_or_gate";
  }'
fi

echo "=== MEASURE TAIL ==="
tail -n 60 "$OUT/${LABEL}_stdout.txt" || true
echo "timeseries=$OUT/${LABEL}_offset_timeseries.csv"
echo "LONG_SOAK_RC=$RC"
exit "$RC"
