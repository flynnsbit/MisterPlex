#!/usr/bin/env bash
# A/B: resolve known +100 ms audio lag between paired fixtures.
#
# HOST MODE (default, no device): measure two local mp4s with avsync_measure_hdmi
#   --input and require Δmedian ≈ +100 ms. This is the RED-before-GREEN gate:
#   if the instrument cannot resolve a designed +100 ms, it cannot adjudicate
#   the user's 480p lipsync complaint.
#
# LIVE MODE (MODE=live): parent has cast rk_zero then rk_plus100 separately;
#   each arm is a grabber soak. REQUIRES single session_epoch per arm (scraped
#   from daemon log). Never pool across session_epoch. Never use av_drift_ms.
#
# Sign: offset_ms=(t_beep−t_flash)*1000; positive = audio LATE.
# delta_ms = median_plus100 − median_zero  (expect ≈ +100).
#
# Capture rc DIRECTLY. rc=77 UNSCORED is never a pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/avsync_hdmi_out/plus100_ab}"
MODE="${MODE:-host}"   # host | live
# Host defaults: AudioID 60s pair (rk=23/24 class)
ZERO_MP4="${ZERO_MP4:-$ROOT/assets/avsync/sync_audio_id_glass_480p24_60s.mp4}"
PLUS_MP4="${PLUS_MP4:-$ROOT/assets/avsync/sync_audio_id_glass_480p24_60s_audioPlus100ms.mp4}"
# Glass-AV 600s pair (rk=20/21 class) override:
#   ZERO_MP4=.../sync_glass_av_480p24_600s.mp4
#   PLUS_MP4=.../sync_glass_av_480p24_600s_audioPlus100ms.mp4
EXPECT_DELTA_MS="${EXPECT_DELTA_MS:-100}"
TOL_DELTA_MS="${TOL_DELTA_MS:-15}"   # |Δ−100| ≤ 15 → PASS instrument
MARKER_PERIOD_S="${MARKER_PERIOD_S:-2.0}"
MIN_PAIRS="${MIN_PAIRS:-8}"
ARM_S="${ARM_S:-45}"                 # live capture seconds per arm
WARMUP_FRAMES="${WARMUP_FRAMES:-0}"  # host file: 0; live grabber: 20
DECODE_SRC="${DECODE_SRC:-caller_supplied}"
LABEL="${LABEL:-p100ab}"
mkdir -p "$OUT"

extract_median() {
  local f="$1"
  awk -F= '/^median_offset_ms_raw=/{print $2; exit}' "$f" | awk '{print $1}'
}
extract_n() {
  local f="$1"
  awk -F= '/^n_pairs=/{print $2; exit}' "$f" | awk '{print $1}'
}

run_file_arm() {
  local name="$1" mp4="$2"
  local dir="$OUT/$name"
  mkdir -p "$dir"
  set +e
  python3 "$ROOT/tools/avsync_measure_hdmi.py" \
    --input "$mp4" \
    --warmup-frames "${WARMUP_FRAMES}" \
    --min-pairs "$MIN_PAIRS" \
    --marker-period-s "$MARKER_PERIOD_S" \
    --tol-ms 500 \
    --no-absolute-score \
    --out "$dir" \
    --label "$name" \
    --json-out "$dir/${name}_report.json" \
    --decode-src "$DECODE_SRC" \
    >"$dir/stdout.txt" 2>&1
  local rc=$?
  set -e
  echo "$rc" >"$dir/measure.rc"
  echo "arm=$name measure true rc=$rc mp4=$mp4"
  local med n
  med=$(extract_median "$dir/stdout.txt")
  n=$(extract_n "$dir/stdout.txt")
  echo "arm=$name median_offset_ms=${med:-NO-DATA} n_pairs=${n:-NO-DATA} src=measured_or_NO-DATA"
  printf 'median_offset_ms=%s\nn_pairs=%s\nrc=%s\n' "${med:-}" "${n:-}" "$rc" >"$dir/summary.txt"
}

run_live_arm() {
  local name="$1"
  local dir="$OUT/$name"
  mkdir -p "$dir"
  # Session gate + epoch stamp
  set +e
  bash "$ROOT/tools/avsync_wait_session.sh" >"$dir/session_gate.txt" 2>&1
  local sg=$?
  set -e
  echo "arm=$name session_gate true rc=$sg"
  if [[ "$sg" -ne 0 ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=session_gate_failed arm=$name"
    exit 77
  fi
  set +e
  bash "$ROOT/tools/avsync_capture_session_epoch.sh" >"$dir/session_epoch.txt" 2>&1
  local er=$?
  set -e
  echo "arm=$name session_epoch_capture true rc=$er"
  cat "$dir/session_epoch.txt" || true
  if [[ "$er" -ne 0 ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=session_epoch_NO-DATA arm=$name"
    exit 77
  fi
  local art="$dir/artifacts.json"
  set +e
  bash "$ROOT/tools/avsync_stamp_artifacts.sh" >"$art" 2>"$dir/artifacts.err"
  set -e
  [[ -s "$art" ]] || echo '{"artifact_pair":"NO-DATA"}' >"$art"
  set +e
  WARMUP_FRAMES="${WARMUP_FRAMES:-20}" \
  DURATION="$ARM_S" MIN_PAIRS="$MIN_PAIRS" MARKER_PERIOD_S="$MARKER_PERIOD_S" \
  TOL_MS=500 LABEL="$name" OUT="$dir" DECODE_SRC="$DECODE_SRC" \
  SKIP_SESSION_GATE=1 \
  bash "$ROOT/tools/avsync_lipsync_soak.sh" >"$dir/soak_wrap.txt" 2>&1
  local rc=$?
  set -e
  echo "arm=$name soak true rc=$rc"
  # Prefer measure stdout under soak out
  local stdout=""
  stdout=$(ls -1 "$dir"/*_stdout.txt 2>/dev/null | head -1 || true)
  if [[ -z "$stdout" || ! -f "$stdout" ]]; then
    stdout="$dir/soak_wrap.txt"
  fi
  local med n
  med=$(extract_median "$stdout")
  n=$(extract_n "$stdout")
  echo "arm=$name median_offset_ms=${med:-NO-DATA} n_pairs=${n:-NO-DATA} src=measured_or_NO-DATA"
  printf 'median_offset_ms=%s\nn_pairs=%s\nrc=%s\n' "${med:-}" "${n:-}" "$rc" >"$dir/summary.txt"
  # copy epoch into summary
  if [[ -f "$dir/session_epoch.txt" ]]; then
    grep -E '^session_epoch=' "$dir/session_epoch.txt" >>"$dir/summary.txt" || \
      echo "session_epoch=NO-DATA" >>"$dir/summary.txt"
  fi
}

echo "=== avsync_plus100_ab ==="
echo "mode=$MODE src=caller_supplied"
echo "expect_delta_ms=$EXPECT_DELTA_MS tol_delta_ms=$TOL_DELTA_MS src=caller_supplied"
echo "sign: offset_ms=(t_beep-t_flash)*1000; + = audio LATE"
echo "delta_ms = median_plus - median_zero; designed content lag +100 ms → delta≈+100"
echo "NOT_USED=av_drift_ms (servo deadband)"
echo "=== PRE-REGISTER ==="
echo "P_DELTA: |delta_ms - $EXPECT_DELTA_MS| <= $TOL_DELTA_MS → INSTRUMENT_RESOLVES_100MS"
echo "P_FAIL:  |delta| < 40 → INSTRUMENT_BLIND (cannot adjudicate user bug)"
echo "predictions_src=caller_supplied_pre_register"

if [[ "$MODE" == "host" ]]; then
  WARMUP_FRAMES="${WARMUP_FRAMES:-0}"
  echo "zero_mp4=$ZERO_MP4 src=caller_supplied"
  echo "plus_mp4=$PLUS_MP4 src=caller_supplied"
  if [[ ! -f "$ZERO_MP4" || ! -f "$PLUS_MP4" ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=mp4_missing"
    exit 77
  fi
  run_file_arm zero "$ZERO_MP4"
  run_file_arm plus "$PLUS_MP4"
elif [[ "$MODE" == "live" ]]; then
  WARMUP_FRAMES="${WARMUP_FRAMES:-20}"
  echo "LIVE: parent must play ZERO fixture, then re-run with PLUS after cast switch."
  echo "This script expects BOTH arms already capturable sequentially under ONE"
  echo "parent orchestration — it measures zero arm now; plus arm requires"
  echo "PLUS_READY=1 and device already on plus100 asset."
  if [[ "${ARM:-zero}" == "zero" ]]; then
    run_live_arm zero
    echo "ZERO_ARM_DONE — cast plus100 asset, then: ARM=plus MODE=live OUT=$OUT bash $0"
    exit 0
  elif [[ "${ARM:-}" == "plus" ]]; then
    run_live_arm plus
  else
    echo "VERDICT=UNSCORED rc=77 reason=ARM_must_be_zero_or_plus"
    exit 77
  fi
else
  echo "VERDICT=UNSCORED rc=77 reason=bad_MODE=$MODE"
  exit 77
fi

# Score A/B if both summaries present
if [[ ! -f "$OUT/zero/summary.txt" || ! -f "$OUT/plus/summary.txt" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=missing_arm_summary"
  exit 77
fi

ZMED=$(awk -F= '/^median_offset_ms=/{print $2}' "$OUT/zero/summary.txt")
PMED=$(awk -F= '/^median_offset_ms=/{print $2}' "$OUT/plus/summary.txt")
ZN=$(awk -F= '/^n_pairs=/{print $2}' "$OUT/zero/summary.txt")
PN=$(awk -F= '/^n_pairs=/{print $2}' "$OUT/plus/summary.txt")
ZE=$(awk -F= '/^session_epoch=/{print $2}' "$OUT/zero/summary.txt" || true)
PE=$(awk -F= '/^session_epoch=/{print $2}' "$OUT/plus/summary.txt" || true)

echo "zero_median_ms=${ZMED:-NO-DATA} n=${ZN:-NO-DATA} session_epoch=${ZE:-n/a} src=measured_or_NO-DATA"
echo "plus_median_ms=${PMED:-NO-DATA} n=${PN:-NO-DATA} session_epoch=${PE:-n/a} src=measured_or_NO-DATA"

if [[ -z "$ZMED" || -z "$PMED" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=median_NO-DATA"
  exit 77
fi
if [[ -z "$ZN" || -z "$PN" || "$ZN" -lt "$MIN_PAIRS" || "$PN" -lt "$MIN_PAIRS" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=insufficient_pairs z=$ZN p=$PN min=$MIN_PAIRS"
  exit 77
fi

DELTA=$(awk -v a="$PMED" -v b="$ZMED" 'BEGIN{printf "%.4f", a-b}')
ERR=$(awk -v d="$DELTA" -v e="$EXPECT_DELTA_MS" 'BEGIN{x=d-e; if(x<0)x=-x; printf "%.4f", x}')
echo "delta_ms=$DELTA src=measured tag=same_tool_B_cancels_on_file_or_same_rig"
echo "abs_err_vs_expect_ms=$ERR expect=$EXPECT_DELTA_MS src=derived"
echo "tol_delta_ms=$TOL_DELTA_MS src=caller_supplied"

FINAL=0
VERDICT=INSTRUMENT_RESOLVES_100MS
if awk -v e="$ERR" -v t="$TOL_DELTA_MS" 'BEGIN{exit !(e+0 > t+0)}'; then
  # Hard blind?
  if awk -v d="$DELTA" 'BEGIN{if(d<0)d=-d; exit !(d+0 < 40)}'; then
    VERDICT=INSTRUMENT_BLIND
    FINAL=2
  else
    VERDICT=DELTA_OFF_EXPECT
    FINAL=2
  fi
fi

echo "VERDICT=$VERDICT rc=$FINAL"
echo "SCORE_PLUS100_AB delta_ms=$DELTA err_ms=$ERR zero_ms=$ZMED plus_ms=$PMED n_zero=$ZN n_plus=$PN verdict=$VERDICT rc=$FINAL src=measured"
echo "PLUS100_AB_RC=$FINAL"
exit "$FINAL"
