#!/usr/bin/env bash
# Transition lipsync harness: measure offset BEFORE and AFTER pause/resume or seek.
# Parent-run only. Does NOT cast the initial play (device must already be on fixture).
# Issues companion transport via HTTP on MISTER_HOST:3005 (same as validate_playback_controls_hw).
#
# Reports step change Δmedian = post_median - pre_median (ms), tags, artifact pair.
# Absolute medians are raw_uncalibrated; Δ cancels fixed grabber latency B on same rig.
# Does NOT use av_drift_ms.
#
# Capture rc DIRECTLY. Soft-skip 77 is NOT a pass.
set -euo pipefail
if [[ -n "${PLXD_SCORE:-}" || -n "${USE_PLXD_FRAMES_DONE:-}" ]]; then
  echo "UNSCORED: PLXD-based scoring is void"
  exit 77
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT/avsync_hdmi_out/transition}"
HOST="${MISTER_HOST:-192.168.1.183}"
PORT="${MISTERPLEX_PORT:-3005}"
# TRANSITION: seek | pause_resume
TRANSITION="${TRANSITION:-seek}"
# seek target ms into stream (rk=27 is 1200s — pick mid-play stable region)
SEEK_MS="${SEEK_MS:-120000}"
ARM_S="${ARM_S:-30}"                 # capture length each side
SETTLE_S="${SETTLE_S:-8}"            # wait after transport before post arm
MARKER_PERIOD_S="${MARKER_PERIOD_S:-2.0}"
MIN_PAIRS="${MIN_PAIRS:-10}"
TOL_MS="${TOL_MS:-200}"
SLOPE_TOL="${SLOPE_TOL_MS_PER_S:-2.0}"  # short arms: slope noisy; not primary
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-hw:0,0}"
VIDEO_SIZE="${VIDEO_SIZE:-1920x1080}"
CAP_FPS="${CAP_FPS:-30}"
WARMUP_FRAMES="${WARMUP_FRAMES:-20}"
SKIP_SESSION_GATE="${SKIP_SESSION_GATE:-0}"
DECODE_SRC="${DECODE_SRC:-caller_supplied}"
# Step-change gate (caller): |Δmedian| above this → TRANSITION_STEP_FAIL rc=2
STEP_TOL_MS="${STEP_TOL_MS:-80}"
LABEL="${LABEL:-xition}"
mkdir -p "$OUT"

cmd_id() { echo "avsx$(date +%s%N)"; }

curl_tl() {
  local wait="${1:-0}"
  curl -fsS --connect-timeout 5 --max-time 15 \
    "http://${HOST}:${PORT}/player/timeline/poll?commandID=$(cmd_id)&wait=${wait}" 2>/dev/null || true
}

xml_attr() {
  local xml="$1" name="$2"
  sed -n "s/.*${name}=\"\([^\"]*\)\".*/\1/p" <<<"$xml" | head -1
}

companion_pause() {
  curl -fsS --connect-timeout 5 --max-time 10 \
    "http://${HOST}:${PORT}/player/playback/pause?commandID=$(cmd_id)" >/dev/null
}
companion_play() {
  curl -fsS --connect-timeout 5 --max-time 10 \
    "http://${HOST}:${PORT}/player/playback/play?commandID=$(cmd_id)" >/dev/null
}
companion_seek() {
  local ms="$1"
  curl -fsS --connect-timeout 5 --max-time 10 \
    "http://${HOST}:${PORT}/player/playback/seekTo?offset=${ms}&commandID=$(cmd_id)" >/dev/null
}

run_arm() {
  local arm_label="$1"
  local arm_out="$OUT/$arm_label"
  mkdir -p "$arm_out"
  local art="$arm_out/artifacts.json"
  local cpu="$arm_out/arm_cpu.json"
  set +e
  bash "$ROOT/tools/avsync_stamp_artifacts.sh" >"$art" 2>"$arm_out/artifacts.err"
  set -e
  [[ -s "$art" ]] || echo '{"rbf_md5":"NO-DATA","daemon_md5":"NO-DATA","artifact_pair":"NO-DATA"}' >"$art"
  (
    bash "$ROOT/tools/avsync_sample_arm_cpu.sh" >"$cpu" 2>/dev/null \
      || echo '{"arm_cpu_pct":null,"arm_cpu_pct_src":"NO-DATA"}' >"$cpu"
  ) &
  local cpid=$!
  sleep 0.15
  set +e
  python3 "$ROOT/tools/avsync_measure_hdmi.py" \
    --duration "$ARM_S" \
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
    --out "$arm_out" \
    --label "$arm_label" \
    --json-out "$arm_out/${arm_label}_report.json" \
    --cpu-pct-json "$cpu" \
    --artifacts-json "$art" \
    --decode-src "$DECODE_SRC" \
    >"$arm_out/${arm_label}_stdout.txt" 2>&1
  local rc=$?
  set -e
  wait "$cpid" 2>/dev/null || true
  echo "$rc" >"$arm_out/measure.rc"
  echo "arm=$arm_label measure true rc=$rc"
  # Extract median
  local med
  med=$(awk -F= '/^median_offset_ms=/{print $2; exit}' "$arm_out/${arm_label}_stdout.txt" | awk '{print $1}')
  local n
  n=$(awk -F= '/^n_pairs=/{print $2; exit}' "$arm_out/${arm_label}_stdout.txt" | awk '{print $1}')
  local sigma
  sigma=$(awk -F= '/^stdev_offset_ms=/{print $2; exit}' "$arm_out/${arm_label}_stdout.txt" | awk '{print $1}')
  if [[ -z "$sigma" ]]; then
    sigma=$(awk '/sigma_ms=/{for(i=1;i<=NF;i++) if($i ~ /^sigma_ms=/){split($i,a,"="); print a[2]}}' \
      "$arm_out/${arm_label}_stdout.txt" | head -1)
  fi
  echo "arm=$arm_label median_offset_ms=${med:-NO-DATA} n_pairs=${n:-NO-DATA} sigma_ms=${sigma:-NO-DATA} src=measured_or_NO-DATA"
  # Write machine-readable arm summary
  {
    echo "median_offset_ms=${med:-}"
    echo "n_pairs=${n:-}"
    echo "sigma_ms=${sigma:-}"
    echo "rc=$rc"
  } >"$arm_out/summary.txt"
  return 0
}

echo "=== avsync_transition_harness ==="
echo "transition=$TRANSITION src=caller_supplied"
echo "arm_s=$ARM_S settle_s=$SETTLE_S seek_ms=$SEEK_MS src=caller_supplied"
echo "marker_period_s=$MARKER_PERIOD_S src=caller_supplied"
echo "step_tol_ms=$STEP_TOL_MS src=caller_supplied"
echo "host=$HOST port=$PORT src=DEFAULT_ASSUMED_or_env"
echo "sign: offset_ms=(t_beep-t_flash)*1000; positive=audio LATE"
echo "delta_sign: delta_median_ms = post - pre; positive => post more LATE than pre"
echo "NOT_USED=av_drift_ms"
echo "limitation: absolute medians raw_uncalibrated; delta cancels fixed grabber B"

if command -v fuser >/dev/null 2>&1; then
  if fuser "$VIDEO_DEV" >/dev/null 2>&1; then
    echo "VERDICT=UNSCORED rc=77 reason=VIDEO_BUSY"
    fuser -v "$VIDEO_DEV" 2>&1 || true
    exit 77
  fi
fi

echo "=== PRE-REGISTERED ==="
echo "P_PRE: n_pairs>=$MIN_PAIRS on pre arm during established play"
echo "P_POST: n_pairs>=$MIN_PAIRS after transition+settle"
echo "P_STEP_NULL: |delta_median_ms| < $STEP_TOL_MS (no large permanent step)"
echo "P_SEEK_RESET: seek may reset stream counters — expected; lipsync must re-lock"
echo "predictions_src=caller_supplied_pre_register"

# Timeline preflight
TL=$(curl_tl 0)
STATE=$(xml_attr "$TL" state)
WALL=$(xml_attr "$TL" time)
echo "timeline_state_pre=${STATE:-NO-DATA} time_ms=${WALL:-NO-DATA} src=measured_or_NO-DATA"
if [[ -z "${STATE}" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=companion_timeline_unreachable host=$HOST:$PORT"
  exit 77
fi
if [[ "$STATE" != "playing" && "$SKIP_SESSION_GATE" != "1" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=not_playing state=$STATE"
  exit 77
fi

if [[ "$SKIP_SESSION_GATE" != "1" ]]; then
  set +e
  bash "$ROOT/tools/avsync_wait_session.sh" >"$OUT/session_gate.txt" 2>&1
  SG_RC=$?
  set -e
  echo "session_gate true rc=$SG_RC"
  if [[ "$SG_RC" -ne 0 ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=session_gate_failed"
    exit 77
  fi
fi

echo "=== PRE ARM ==="
run_arm "pre"
PRE_RC=$(cat "$OUT/pre/measure.rc")
PRE_MED=$(awk -F= '/^median_offset_ms=/{print $2}' "$OUT/pre/summary.txt")
PRE_N=$(awk -F= '/^n_pairs=/{print $2}' "$OUT/pre/summary.txt")
PRE_SIG=$(awk -F= '/^sigma_ms=/{print $2}' "$OUT/pre/summary.txt")

if [[ "$PRE_RC" -ne 0 && "$PRE_RC" -ne 4 && "$PRE_RC" -ne 5 ]]; then
  # 0 PASS, 4 DRIFT, 5 WANDER still have pairs; 77/3 no data
  if [[ -z "$PRE_MED" || -z "$PRE_N" || "${PRE_N:-0}" -lt "$MIN_PAIRS" ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=pre_arm_unscored pre_rc=$PRE_RC n=${PRE_N:-NO-DATA}"
    exit 77
  fi
fi

echo "=== TRANSITION action=$TRANSITION ==="
set +e
case "$TRANSITION" in
  seek)
    companion_seek "$SEEK_MS"
    TRC=$?
    echo "seekTo offset_ms=$SEEK_MS true rc=$TRC"
    ;;
  pause_resume)
    companion_pause
    PRC=$?
    echo "pause true rc=$PRC"
    sleep 2
    companion_play
    RRC=$?
    echo "play/resume true rc=$RRC"
    TRC=$(( PRC != 0 ? PRC : RRC ))
    ;;
  *)
    echo "VERDICT=UNSCORED rc=77 reason=unknown_TRANSITION=$TRANSITION"
    exit 77
    ;;
esac
set -e

echo "settle_s=$SETTLE_S src=caller_supplied"
sleep "$SETTLE_S"
TL2=$(curl_tl 0)
STATE2=$(xml_attr "$TL2" state)
WALL2=$(xml_attr "$TL2" time)
echo "timeline_state_post_settle=${STATE2:-NO-DATA} time_ms=${WALL2:-NO-DATA} src=measured_or_NO-DATA"
if [[ "${STATE2:-}" != "playing" && "$SKIP_SESSION_GATE" != "1" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=not_playing_after_transition state=$STATE2"
  exit 77
fi

echo "=== POST ARM ==="
run_arm "post"
POST_RC=$(cat "$OUT/post/measure.rc")
POST_MED=$(awk -F= '/^median_offset_ms=/{print $2}' "$OUT/post/summary.txt")
POST_N=$(awk -F= '/^n_pairs=/{print $2}' "$OUT/post/summary.txt")
POST_SIG=$(awk -F= '/^sigma_ms=/{print $2}' "$OUT/post/summary.txt")

if [[ -z "$PRE_MED" || -z "$POST_MED" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=missing_median pre=${PRE_MED:-NO-DATA} post=${POST_MED:-NO-DATA}"
  echo "pre_rc=$PRE_RC post_rc=$POST_RC"
  exit 77
fi
if [[ -z "$PRE_N" || -z "$POST_N" || "$PRE_N" -lt "$MIN_PAIRS" || "$POST_N" -lt "$MIN_PAIRS" ]]; then
  echo "VERDICT=UNSCORED rc=77 reason=insufficient_pairs pre_n=${PRE_N:-NO-DATA} post_n=${POST_N:-NO-DATA} min=$MIN_PAIRS"
  exit 77
fi

# Δ and SE of difference (independent arms)
DELTA=$(awk -v a="$POST_MED" -v b="$PRE_MED" 'BEGIN{printf "%.4f", a-b}')
# se_median ≈ 1.2533*sigma/sqrt(n); se_delta = hypot(se_pre, se_post)
SE_DELTA=$(awk -v sp="${PRE_SIG:-nan}" -v sn="$PRE_N" -v tp="${POST_SIG:-nan}" -v tn="$POST_N" 'BEGIN{
  if(sp!="nan" && sp!="" && sn+0>0) se1=1.2533*sp/sqrt(sn); else se1=0;
  if(tp!="nan" && tp!="" && tn+0>0) se2=1.2533*tp/sqrt(tn); else se2=0;
  printf "%.4f", sqrt(se1*se1+se2*se2);
}')
ABS_D=$(awk -v d="$DELTA" 'BEGIN{if(d<0)d=-d; printf "%.4f", d}')

echo "=== TRANSITION RESULT ==="
echo "pre_median_offset_ms=$PRE_MED src=measured tag=raw_uncalibrated n=$PRE_N"
echo "post_median_offset_ms=$POST_MED src=measured tag=raw_uncalibrated n=$POST_N"
echo "delta_median_ms=$DELTA src=measured tag=same_rig_B_cancels"
echo "se_delta_ms=$SE_DELTA src=derived"
echo "step_tol_ms=$STEP_TOL_MS src=caller_supplied"
echo "pre_rc=$PRE_RC post_rc=$POST_RC src=measured"
echo "transition=$TRANSITION seek_ms=$SEEK_MS src=caller_supplied"

# Artifact pair from post arm (should match pre)
if [[ -f "$OUT/post/artifacts.json" ]]; then
  echo "artifacts_post=$(tr -d '\n' <"$OUT/post/artifacts.json")"
fi

FINAL_RC=0
VERDICT=PASS
if awk -v a="$ABS_D" -v t="$STEP_TOL_MS" 'BEGIN{exit !(a+0 > t+0)}'; then
  VERDICT=TRANSITION_STEP_FAIL
  FINAL_RC=2
  echo "VERDICT=$VERDICT rc=$FINAL_RC reason=abs_delta_median_ms=$ABS_D > step_tol_ms=$STEP_TOL_MS"
  echo "verdict_note: step change is grabber-side lipsync shift across transport; NOT av_drift_ms"
else
  echo "VERDICT=$VERDICT rc=$FINAL_RC reason=abs_delta_median_ms=$ABS_D <= step_tol_ms=$STEP_TOL_MS"
  echo "verdict_note: PASS is step-stability only; absolute still raw_uncalibrated"
fi

echo "SCORE_TRANSITION delta_ms=$DELTA se_delta_ms=$SE_DELTA pre_ms=$PRE_MED post_ms=$POST_MED n_pre=$PRE_N n_post=$POST_N transition=$TRANSITION verdict=$VERDICT rc=$FINAL_RC src=measured"
echo "TRANSITION_RC=$FINAL_RC"
exit "$FINAL_RC"
