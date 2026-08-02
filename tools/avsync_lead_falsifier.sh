#!/usr/bin/env bash
# AV_PRESENT_LEAD_MS falsifier — PARENT RUNS THIS (agent never restarts daemon).
#
# PURPOSE: prove av_drift_ms is circular (tracks setpoint) vs external HDMI
# lipsync which is the only GT. Quote host/libmisterplex/av_clock.hpp:
#   av_drift_ms sits in approximately [-lead, drop) BY CONSTRUCTION.
#   av_drift_role=servo_error_not_lipsync
#
# Env override (main.cpp): MISTERPLEX_AV_PRESENT_LEAD_MS wins over conf and
# prints "conf not modified". Prefer env; backup conf anyway.
#
# This script does NOT restart the daemon. It:
#   1) prints the exact parent procedure + pre-registered predictions
#   2) optionally scrapes av_drift_ms from a provided log (LOG_A / LOG_B)
#   3) optionally scores two HDMI measure report JSONs (REPORT_A / REPORT_B)
#
# Modes:
#   card          — print procedure only (default)
#   score_logs    — compare av_drift medians from LOG_A LOG_B
#   score_hdmi    — compare HDMI medians from REPORT_A REPORT_B (json or stdout)
#   score_both    — both
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-card}"
OUT="${OUT:-$ROOT/avsync_hdmi_out/lead_falsifier}"
mkdir -p "$OUT"

cat <<'BANNER'
=== avsync_lead_falsifier ===
QUOTE av_clock.hpp: av_drift_ms ∈ [-lead, drop) BY CONSTRUCTION;
  av_drift_role=servo_error_not_lipsync — NOT lipsync GT.
QUOTE main.cpp: MISTERPLEX_AV_PRESENT_LEAD_MS overrides conf; conf not modified.

Sign HDMI: offset_ms=(t_beep-t_flash)*1000; + = audio LATE.
session_epoch: each arm must be a single epoch (supply_bucket); never pool.

=== PRE-REGISTERED PREDICTIONS (publish hit/miss after run) ===
Sequence: L40a → L20 → L40b (return-to-baseline). No conf edit.
P_SERVO_40: LEAD=40 → av_drift_ms median ∈ [-45, -25]  (setpoint -40)
P_SERVO_20: LEAD=20 → av_drift_ms median ∈ [-28, -10]  (setpoint -20)
P_SERVO_Δ40→20: median_20 − median_40a ∈ [+12, +28] ms  (~ +|Δlead|)
P_SERVO_Δ20→40b: median_40b − median_20 ∈ [-28, -12] ms
  IF TRUE → drift TRACKS lead (setpoint readout / closed loop). NOT lipsync GT.
  IF STATIC in [-45,-15] across LEAD → refuted as lipsync proxy; still not GT.
P_BANNER: each arm log shows AV_PRESENT_LEAD_MS=env:N and "conf not modified"
P_CONF:   misterplex.conf never written (daily driver)
P_EPOCH:  single session_epoch within each arm (multi-epoch arm → UNSCORED 77)
P_HDMI:   optional only if grabber lives; not required for S3 servo test
See docs/AVSYNC_S3_PARENT_RUN.md for full parent card.
BANNER

if [[ "$MODE" == "card" ]]; then
  cat <<'PROC'

=== PARENT PROCEDURE (exact) — env via supervise, NO conf write ===

# Device is daily driver. Prefer supervise env inherit only.
# Quote main.cpp:626-633 MISTERPLEX_AV_PRESENT_LEAD_MS; banner ~:668 env:N
# Supervise: /media/fat/misterplex_v2/bin/misterplexd_supervise.sh
#   spawns "$BIN" inheriting env; flock on /tmp/misterplexd_supervise.lock

HOST=${MISTER_HOST:-192.168.1.183}
OUTROOT=$PWD/.agent-work/w-avsync/s3_lead_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUTROOT"

# For LEAD in 40 20 40 (tags L40a L20 L40b):
# 1) Stop supervise cleanly (no kill -9 thrash). Export LEAD in that shell:
#      export MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD
#      nohup env MISTERPLEX_AV_PRESENT_LEAD_MS=$LEAD \
#        /media/fat/misterplex_v2/bin/misterplexd_supervise.sh \
#        >/tmp/supervise_lead.log 2>&1 &
# 2) PROVE banner (do not assume):
#      grep -E 'AV_PRESENT_LEAD_MS=|conf not modified' LOG | tail -5
#      expect: AV_PRESENT_LEAD_MS=env:$LEAD
# 3) Cast DIRECT-PLAY ≥30 s steady. One session_epoch per arm.
# 4) Pull: grep av_drift_ms=|session_epoch= → $OUTROOT/<tag>/daemon_tail.txt
# 5) Median n≥8; score pairwise Δ against P_SERVO_Δ*
# 6) Optional HDMI soak only if grabber lock OK — not required for S3.

# Score servo-only (no HDMI):
#   LOG_A=$OUTROOT/L40a/daemon_tail.txt LOG_B=$OUTROOT/L20/daemon_tail.txt \
#     bash tools/avsync_lead_falsifier.sh score_logs
#   echo "true rc=$?"
# expect: AV_DRIFT_CIRCULAR rc=0 if Δ∈[+12,+28]

# Full doc: docs/AVSYNC_S3_PARENT_RUN.md
# Intermittent supply ~25%: do NOT use LEAD arms as supply A/B.

PROC
  exit 0
fi

median_from_av_drift_log() {
  local log="$1"
  # Extract av_drift_ms=N from log; median via python
  python3 - "$log" <<'PY'
import re, statistics, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print("NO-DATA")
    sys.exit(0)
text = p.read_text(errors="replace")
vals = [float(x) for x in re.findall(r"\bav_drift_ms=(-?[0-9]+(?:\.[0-9]+)?)", text)]
if not vals:
    print("NO-DATA")
else:
    print(f"{statistics.median(vals):.4f}")
    print(f"n={len(vals)}", file=sys.stderr)
PY
}

median_from_hdmi_report() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "NO-DATA"
    return
  fi
  # stdout style or json
  if grep -q 'median_offset_ms_raw=' "$f" 2>/dev/null; then
    awk -F= '/^median_offset_ms_raw=/{print $2; exit}' "$f" | awk '{print $1}'
    return
  fi
  python3 - "$f" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    doc = json.loads(p.read_text())
except Exception:
    print("NO-DATA")
    raise SystemExit
res = doc.get("result") or doc
med = res.get("median_offset_ms")
print(med if med is not None else "NO-DATA")
PY
}

score_servo() {
  local la="${LOG_A:-}" lb="${LOG_B:-}"
  echo "=== score_logs (av_drift_ms — CIRCULARITY check) ==="
  if [[ -z "$la" || -z "$lb" || ! -f "$la" || ! -f "$lb" ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=LOG_A_or_LOG_B_missing"
    return 77
  fi
  local ma mb
  ma=$(median_from_av_drift_log "$la")
  mb=$(median_from_av_drift_log "$lb")
  echo "av_drift_median_A_LEAD40=$ma src=measured_or_NO-DATA"
  echo "av_drift_median_B_LEAD20=$mb src=measured_or_NO-DATA"
  if [[ "$ma" == "NO-DATA" || "$mb" == "NO-DATA" ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=av_drift_median_NO-DATA"
    return 77
  fi
  local d
  d=$(awk -v a="$mb" -v b="$ma" 'BEGIN{printf "%.4f", a-b}')
  echo "av_drift_delta_BminusA_ms=$d src=derived"
  echo "expect_delta_ms_range=[12,28] src=caller_supplied_pre_register"
  if awk -v d="$d" 'BEGIN{exit !((d+0)>=12 && (d+0)<=28)}'; then
    echo "VERDICT=AV_DRIFT_CIRCULAR rc=0 reason=delta_tracks_setpoint_delta_lead"
    echo "verdict_note: av_drift_ms MUST NOT be used as lipsync GT (confirmed circular)"
    return 0
  else
    echo "VERDICT=AV_DRIFT_UNEXPECTED rc=2 reason=delta_outside_12_28 d=$d"
    echo "verdict_note: unexpected — re-check LEAD banners env:40/env:20 and single epoch"
    return 2
  fi
}

score_hdmi() {
  local ra="${REPORT_A:-}" rb="${REPORT_B:-}"
  echo "=== score_hdmi (external lipsync Δ) ==="
  if [[ -z "$ra" || -z "$rb" || ! -f "$ra" || ! -f "$rb" ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=REPORT_A_or_REPORT_B_missing"
    return 77
  fi
  local ma mb
  ma=$(median_from_hdmi_report "$ra")
  mb=$(median_from_hdmi_report "$rb")
  echo "hdmi_median_A_LEAD40=$ma src=measured_or_NO-DATA tag=raw_uncalibrated"
  echo "hdmi_median_B_LEAD20=$mb src=measured_or_NO-DATA tag=raw_uncalibrated"
  if [[ "$ma" == "NO-DATA" || "$mb" == "NO-DATA" || -z "$ma" || -z "$mb" ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=hdmi_median_NO-DATA"
    return 77
  fi
  local d
  d=$(awk -v a="$mb" -v b="$ma" 'BEGIN{printf "%.4f", a-b}')
  echo "hdmi_delta_BminusA_ms=$d src=measured tag=same_rig_B_cancels"
  echo "pre_register_expect_ms≈+20 ±15 src=caller_supplied_mechanism"
  # Classify
  if awk -v d="$d" 'BEGIN{x=d-20; if(x<0)x=-x; exit !(x<=15)}'; then
    echo "VERDICT=HDMI_TRACKS_LEAD rc=0 reason=delta≈+20_as_predicted"
    return 0
  elif awk -v d="$d" 'BEGIN{if(d<0)d=-d; exit !(d<=8)}'; then
    echo "VERDICT=HDMI_DECOUPLED_FROM_LEAD rc=0 reason=delta≈0_while_lead_changed"
    echo "verdict_note: external lipsync unchanged by LEAD; servo may still be circular"
    return 0
  else
    echo "VERDICT=HDMI_DELTA_OTHER rc=2 reason=d=$d_not_near_0_or_plus20"
    return 2
  fi
}

rc=0
case "$MODE" in
  score_logs) score_servo; rc=$? ;;
  score_hdmi) score_hdmi; rc=$? ;;
  score_both)
    set +e
    score_servo; r1=$?
    score_hdmi; r2=$?
    set -e
    echo "servo_rc=$r1 hdmi_rc=$r2"
    if [[ "$r1" -eq 77 || "$r2" -eq 77 ]]; then rc=77
    elif [[ "$r1" -ne 0 || "$r2" -ne 0 ]]; then rc=2
    else rc=0
    fi
    ;;
  *)
    echo "usage: $0 [card|score_logs|score_hdmi|score_both]"
    exit 1
    ;;
esac
echo "LEAD_FALSIFIER_RC=$rc"
exit "$rc"
