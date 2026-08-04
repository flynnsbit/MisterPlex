#!/usr/bin/env bash
# post_sole_harvest.sh — parent/w-integ post-sole package gates for a remote_out SLOT.
#
# Does NOT start Quartus, does NOT deploy, does NOT touch the device.
# BUILD_OK_PACKAGE is YES only when FullComp0 AND hierarchy true rc=0 AND timing true rc=0.
# Soft-skip (rc=77) is never treated as PASS. Missing artifacts → honest rc≠0 (dry-run ok).
#
# Usage:
#   scripts/post_sole_harvest.sh [SLOT]
#   SLOT=cutb-sched-reg WAIT=1 WAIT_SECS=3600 scripts/post_sole_harvest.sh
#   scripts/post_sole_harvest.sh cutb-sched-reg --wait
#
# Env:
#   SLOT          default: cutb-sched-reg
#   WAIT          1 = poll until required artifacts exist or WAIT_SECS elapses (default 0)
#   WAIT_SECS     poll budget seconds (default 7200)
#   POLL_SECS     poll interval (default 30)
#   ROOT          worktree root (default: derived from this script)
#   LAB_STATUS    Memory lab status dir (default: ~/Projects/MisterPlex/Memory/lab/status)
#   LEDGER        optional path for harvest ledger (default: $LAB_STATUS/HARVEST_${SLOT}.txt)
#   PRODUCT_WIRE  recorded only; never set to 1 by this script (default 0)
#
# Exit:
#   0  BUILD_OK_PACKAGE=YES (FullComp0 + hierarchy + timing)
#   1  gates ran and at least one package gate failed (or summary/RBF incomplete)
#   2  usage / bad env
#   4  required artifacts missing (dry-run / wait timeout) — not BUILD_OK
#   77 never remapped to 0; if hierarchy/timing returned 77, package stays NO and exit 1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LAB_STATUS="${LAB_STATUS:-$HOME/Projects/MisterPlex/Memory/lab/status}"
PRODUCT_WIRE="${PRODUCT_WIRE:-0}"
WAIT="${WAIT:-0}"
WAIT_SECS="${WAIT_SECS:-7200}"
POLL_SECS="${POLL_SECS:-30}"

SLOT="${SLOT:-cutb-sched-reg}"
for arg in "$@"; do
  case "$arg" in
    --wait|-w) WAIT=1 ;;
    --help|-h)
      sed -n '2,35p' "$0"
      exit 0
      ;;
    -*)
      echo "unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      SLOT="$arg"
      ;;
  esac
done

OUT="$ROOT/fpga/Plex_MiSTer/remote_out/$SLOT"
RBF="$OUT/Plex.rbf"
STA="$OUT/Plex.sta.rpt"
FIT="$OUT/Plex.fit.rpt"
MAP="$OUT/Plex.map.rpt"
COMPILE_LOG="$OUT/compile.log"
SUMMARY="$OUT/summary.txt"
# Task pattern: CUTB_RBF_${SLOT}.txt (prior shorts stripped cutb-; this is unambiguous).
MD5_RECORD="${MD5_RECORD:-$LAB_STATUS/CUTB_RBF_${SLOT}.txt}"
LEDGER="${LEDGER:-$LAB_STATUS/HARVEST_${SLOT}.txt}"
RCA="${RCA:-/tmp/${SLOT}-RCA.txt}"

HIER_PY="$ROOT/scripts/check_quartus_fit_hierarchy.py"
TIMING_PY="$ROOT/scripts/check_quartus_timing.py"

ts() { date -Iseconds 2>/dev/null || date; }

echo "=== post_sole_harvest $(ts) ==="
echo "ROOT=$ROOT"
echo "SLOT=$SLOT"
echo "OUT=$OUT"
echo "PRODUCT_WIRE=$PRODUCT_WIRE (this script never deploys; never starts Quartus)"
echo "WAIT=$WAIT WAIT_SECS=$WAIT_SECS"
if [[ -d "$ROOT/.git" ]] || [[ -f "$ROOT/.git" ]]; then
  TIP="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
else
  TIP=unknown
fi
echo "TIP=$TIP"

required_present() {
  [[ -f "$RBF" && -f "$STA" && -f "$FIT" && -f "$MAP" ]]
}

list_artifacts() {
  if [[ -d "$OUT" ]]; then
    ls -la "$OUT" 2>/dev/null || true
  else
    echo "OUT dir absent: $OUT"
  fi
}

if [[ "$WAIT" == "1" ]]; then
  deadline=$(( $(date +%s) + WAIT_SECS ))
  echo "waiting for remote_out artifacts under $OUT (budget ${WAIT_SECS}s)..."
  while ! required_present; do
    now=$(date +%s)
    if (( now >= deadline )); then
      echo "WAIT_TIMEOUT: required artifacts not present after ${WAIT_SECS}s" >&2
      list_artifacts
      echo "BUILD_OK_PACKAGE=NO (artifacts missing after wait)"
      exit 4
    fi
    # Do not re-launch fit; observe only.
    pgrep -af "build_rbf_remote.sh ${SLOT}|mplex-fit-.*${SLOT}|quartus_fit.*Plex" 2>/dev/null || true
    sleep "$POLL_SECS"
  done
  echo "artifacts present $(ts)"
fi

if ! required_present; then
  echo "ARTIFACTS_MISSING: need Plex.rbf Plex.sta.rpt Plex.fit.rpt Plex.map.rpt under $OUT"
  list_artifacts
  echo "post-fit-hierarchy true rc=NA (not run)"
  echo "post-fit-timing true rc=NA (not run)"
  echo "BUILD_OK_PACKAGE=NO (dry-run / artifacts not ready)"
  echo "PRODUCT_WIRE=$PRODUCT_WIRE"
  # Honest non-zero; not BUILD_OK. Parent may re-run after copy-back.
  exit 4
fi

echo "--- artifacts ---"
list_artifacts

# --- FullComp0 ---
FULLCOMP0=0
SUMMARY_EXIT=""
if [[ -f "$SUMMARY" ]]; then
  SUMMARY_EXIT="$(grep -E '^exit_code=' "$SUMMARY" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
  echo "summary.txt: $(tr '\n' ' ' <"$SUMMARY" | sed 's/  */ /g')"
  if [[ "$SUMMARY_EXIT" == "0" ]]; then
    FULLCOMP0=1
  fi
else
  echo "summary.txt ABSENT — FullComp0 cannot be proven from summary; RBF present still required"
fi
if [[ ! -f "$RBF" ]]; then
  FULLCOMP0=0
fi
# FullComp0 := exit_code=0 AND Plex.rbf exists (recipe). If summary absent but RBF+rpts exist
# after a partial copy, keep FULLCOMP0=0 (cannot invent compile success).
echo "FullComp0=$FULLCOMP0 (summary exit_code=${SUMMARY_EXIT:-ABSENT}, rbf=$([[ -f $RBF ]] && echo yes || echo no))"

# --- Hierarchy (true rc, no pipe that eats $?) ---
# Capture with || so a future set -e cannot skip the echo.
HIER_RC=0
if [[ -f "$COMPILE_LOG" ]]; then
  "$HIER_PY" --fit-rpt "$FIT" --map-rpt "$MAP" --log "$COMPILE_LOG" || HIER_RC=$?
else
  echo "compile.log absent — hierarchy without --log"
  "$HIER_PY" --fit-rpt "$FIT" --map-rpt "$MAP" || HIER_RC=$?
fi
echo "post-fit-hierarchy true rc=$HIER_RC"

BUILD_ID_PRESENT=NO
if grep -q 'plex_rbf_build_id:u_rbf_build_id' "$FIT" "$MAP" 2>/dev/null; then
  BUILD_ID_PRESENT=YES
fi
echo "build_id_PRESENT=$BUILD_ID_PRESENT (plex_rbf_build_id:u_rbf_build_id in fit/map)"

HIERARCHY_OK=0
if [[ "$HIER_RC" -eq 0 ]]; then
  HIERARCHY_OK=1
fi
# Note: build_id PRESENT is part of the hierarchy config fixtures when the gate is green;
# we still record the spot-check. Do not invent PASS if gate rc≠0 even if string greps.

# --- Timing (true rc, no pipe that eats $?) ---
TIMING_RC=0
"$TIMING_PY" --sta-rpt "$STA" || TIMING_RC=$?
echo "post-fit-timing true rc=$TIMING_RC"

TIMING_OK=0
if [[ "$TIMING_RC" -eq 0 ]]; then
  TIMING_OK=1
fi
# rc=77 soft-skip / UNSCORED is NOT package PASS
if [[ "$TIMING_RC" -eq 77 ]]; then
  echo "TIMING soft-skip rc=77 ≠ PASS; TIMING_OK forced 0"
  TIMING_OK=0
fi
if [[ "$HIER_RC" -eq 77 ]]; then
  echo "HIERARCHY soft-skip rc=77 ≠ PASS; HIERARCHY_OK forced 0"
  HIERARCHY_OK=0
fi

# --- md5 record (always when RBF exists; does not imply BUILD_OK) ---
NEW_MD5=""
mkdir -p "$LAB_STATUS"
if [[ -f "$RBF" ]]; then
  # Capture md5 without losing $? of gates; standalone command.
  NEW_MD5="$(md5sum "$RBF" | awk '{print $1}')"
  # Permanent record format matches prior CUTB_RBF_*.txt (md5  path)
  printf '%s  %s\n' "$NEW_MD5" "$RBF" | tee "$MD5_RECORD"
  echo "RBF_MD5_RECORD=$MD5_RECORD"
  # Convenience short copy under /tmp (ephemeral)
  printf '%s  %s\n' "$NEW_MD5" "$RBF" >"/tmp/CUTB_RBF_${SLOT}.md5" 2>/dev/null || true
else
  echo "RBF missing — no md5 record" >&2
fi

# --- BUILD_OK_PACKAGE strict AND ---
BUILD_OK_PACKAGE=NO
if [[ "$FULLCOMP0" -eq 1 && "$HIERARCHY_OK" -eq 1 && "$TIMING_OK" -eq 1 ]]; then
  BUILD_OK_PACKAGE=YES
fi

{
  echo "=== HARVEST LEDGER ${SLOT} $(ts) ==="
  echo "SLOT=$SLOT"
  echo "TIP=$TIP"
  echo "PRODUCT_WIRE=$PRODUCT_WIRE"
  echo "OUT=$OUT"
  echo "summary_exit_code=${SUMMARY_EXIT:-ABSENT}"
  echo "FullComp0=$FULLCOMP0"
  echo "NEW_MD5=${NEW_MD5:-}"
  echo "RBF_MD5_RECORD=$MD5_RECORD"
  echo "post-fit-hierarchy true rc=$HIER_RC"
  echo "build_id_PRESENT=$BUILD_ID_PRESENT"
  echo "post-fit-timing true rc=$TIMING_RC"
  echo "HIERARCHY_OK=$HIERARCHY_OK"
  echo "TIMING_OK=$TIMING_OK"
  echo "BUILD_OK_PACKAGE=$BUILD_OK_PACKAGE"
  echo "DEPLOY=NO (this script never deploys; parent ONE menu only after BUILD_OK_PACKAGE=YES)"
  echo "QUARTUS_START=NO"
} | tee "$LEDGER"

echo "LEDGER=$LEDGER"

if [[ "$BUILD_OK_PACKAGE" != "YES" ]]; then
  # RCA dump for parent / w-clock — still no deploy
  {
    echo "=== ${SLOT} RCA $(ts) ==="
    echo "TIP=$TIP"
    echo "BUILD_OK_PACKAGE=NO"
    echo "FullComp0=$FULLCOMP0 summary_exit=${SUMMARY_EXIT:-ABSENT}"
    echo "post-fit-hierarchy true rc=$HIER_RC build_id_PRESENT=$BUILD_ID_PRESENT"
    echo "post-fit-timing true rc=$TIMING_RC"
    echo "NEW_MD5=${NEW_MD5:-}"
    echo "--- summary ---"
    cat "$SUMMARY" 2>/dev/null || echo "(no summary)"
    echo "--- timing re-echo (detail already above) ---"
    echo "STA=$STA"
    echo "--- hierarchy spot ---"
    grep -n 'plex_rbf_build_id:u_rbf_build_id' "$FIT" "$MAP" 2>/dev/null | head -20 || true
    if [[ -f "$STA" ]]; then
      echo "--- STA Setup/Fmax clues (head) ---"
      grep -nE 'Setup Summary|Fmax Summary|clk_ddr|general\[2\]' "$STA" 2>/dev/null | head -80 || true
    fi
  } | tee "$RCA"
  echo "RCA=$RCA"
  echo "BUILD_OK_PACKAGE=NO — do not deploy; do not invent BUILD_OK"
  # Prefer rc=1 for gate failure; keep 4 only for missing artifacts (handled above).
  exit 1
fi

echo "BUILD_OK_PACKAGE=YES — FullComp0 AND hierarchy AND timing true pass"
echo "DEPLOY: parent only — DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh $RBF"
echo "PRODUCT_WIRE remains $PRODUCT_WIRE until parent program"
exit 0
