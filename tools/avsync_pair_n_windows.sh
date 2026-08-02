#!/usr/bin/env bash
# N-window paired daemon×HDMI protocol (parent-run). Agent does not touch device.
#
# Requires tip daemon with pub_iv_* on 1 Hz lines (deploy after w-geom M2 commit).
# Wraps tools/avsync_pair_daemon_hdmi.sh (live log resolve; no v1 default).
#
# Usage:
#   # 480p daily tier already casting soak/blip; grabber free:
#   N=6 DURATION=60 TIER=480p \
#     OUT_ROOT=$PWD/.agent-work/w-geom/m2_n6_480p_$(date +%Y%m%dT%H%M%S) \
#     bash tools/avsync_pair_n_windows.sh
#   echo "true rc=$?"
#
#   # 240p control (change conf / cast 240 tier yourself first):
#   N=6 TIER=240p OUT_ROOT=... bash tools/avsync_pair_n_windows.sh
#
# LOOK_AT each window:
#   pair_correlation.txt → timing_class, residual_rms_ms, pub_iv_p_ge50_w60,
#   mechanism_hits (M2_CONFIRMED_*), m1_status
# Summary: $OUT_ROOT/n_windows_summary.txt
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="${N:-6}"
DUR="${DURATION:-60}"
TOL="${TOL_MS:-42}"
TIER="${TIER:-480p}"
GAP_S="${GAP_S:-5}"
OUT_ROOT="${OUT_ROOT:-$ROOT/.agent-work/w-geom/m2_n${N}_${TIER}}"
mkdir -p "$OUT_ROOT"

echo "=== avsync_pair_n_windows ==="
echo "n=$N duration=$DUR tier=$TIER out_root=$OUT_ROOT gap_s=$GAP_S"
echo "PRE_REG M1=FALSIFIED_parent_pair primary=M2_PUBLISH_INTERVAL"
echo "PRE_REG WANDER+p_ge50_w60>=0.03 => M2a/c; WANDER+CLEAN p_ge50 => M2e; STABLE+p_ge50>=0.09 => MISS"
echo "PRE_REG_FILE=$ROOT/.agent-work/w-geom/M2_PUBLISH_INTERVAL_RCA.md"

SUMMARY="$OUT_ROOT/n_windows_summary.txt"
{
  echo "tier=$TIER n=$N duration=$DUR started=$(date -Is)"
  echo "cols=i,out,soak_rc,corr_rc,timing_class,residual_rms_ms,detrended_max,vfps_p50,drops_delta,p_ge50_w60,hits"
} >"$SUMMARY"

fail=0
for i in $(seq 1 "$N"); do
  OUT="$OUT_ROOT/w$(printf '%02d' "$i")"
  echo ""
  echo "===== WINDOW $i / $N OUT=$OUT ====="
  set +e
  OUT="$OUT" DURATION="$DUR" TOL_MS="$TOL" LABEL="pair" \
    bash "$ROOT/tools/avsync_pair_daemon_hdmi.sh"
  rc=$?
  set -e
  echo "window_$i true rc=$rc"

  # Parse correlation text if present
  ct="$OUT/pair_correlation.txt"
  tc="NO-DATA"; rms="NO-DATA"; dmax="NO-DATA"; v50="NO-DATA"; dd="NO-DATA"; pge="NO-DATA"; hits="NO-DATA"
  if [[ -f "$ct" ]]; then
    tc=$(sed -n 's/.*timing_class=\([A-Z_]*\).*/\1/p' "$ct" | head -1)
    rms=$(sed -n 's/.*residual_rms_ms=\([0-9.]*\).*/\1/p' "$ct" | head -1)
    dmax=$(sed -n 's/.*detrended_max_abs_ms=\([0-9.]*\).*/\1/p' "$ct" | head -1)
    # mechanism_inputs line may hold vfps
    v50=$(sed -n "s/.*'vfps_p50': \([0-9.]*\).*/\1/p" "$ct" | head -1)
    dd=$(sed -n "s/.*'drops_delta': \([0-9.]*\).*/\1/p" "$ct" | head -1)
    pge=$(sed -n "s/.*'pub_iv_p_ge50_w60_p50': \([0-9.]*\).*/\1/p" "$ct" | head -1)
    hits=$(sed -n 's/^mechanism_hits=//p' "$ct" | head -1)
  fi
  echo "$i,$OUT,$rc,$rc,${tc:-NO-DATA},${rms:-NO-DATA},${dmax:-NO-DATA},${v50:-NO-DATA},${dd:-NO-DATA},${pge:-NO-DATA},${hits:-NO-DATA}" \
    >>"$SUMMARY"

  if [[ "$rc" -ne 0 && "$rc" -ne 5 ]]; then
    # rc=5 is WANDER_FAIL from instrument — still a scored window
    :
  fi
  if [[ "$i" -lt "$N" ]]; then
    sleep "$GAP_S"
  fi
done

echo ""
echo "=== SUMMARY $SUMMARY ==="
cat "$SUMMARY"
echo "LOOK_AT: count timing_class=WANDER vs STABLE; compare p_ge50_w60 on each class"
echo "DONE n_windows tier=$TIER"
# Overall rc=0 if at least one window produced correlation; else 77
if grep -q 'timing_class=WANDER\|timing_class=STABLE\|,WANDER,\|,STABLE,' "$SUMMARY" 2>/dev/null \
  || grep -qE 'WANDER|STABLE' "$SUMMARY"; then
  exit 0
fi
exit 77
