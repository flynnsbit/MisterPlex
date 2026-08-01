#!/usr/bin/env bash
# run_real_geom_matrix.sh — real BBB / non-fixture geometry matrix via cast-picker E2E.
#
# Keys (parent library, ratingKey only — never title):
#   29 624x352 90s   — crop/pad path (interesting)
#   30 624x480 1200s — real BBB bank-sized
#   31 640x480 90s
#   32 720x480 90s   — scale path (interesting)
#
# Asserts MEASURED_DELIVERY (not request/library) + desync_risk!=1 + N transitions
# + session_epoch stable within each continuous-play window.
#
# Does NOT open /dev/video0. Does NOT ssh. Parent feeds daemon log snip when
# :3005/player/telemetry lacks measured_delivery (common on older deploys).
#
# Exit: 0 all keys PASS | 1 any FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS
# rc=77 is NEVER a pass.
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_CONTENT="${E2E_CONTENT:-real}"
export E2E_REAL_GEOM_MATRIX="${E2E_REAL_GEOM_MATRIX:-1}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-10}"
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-1}"
export E2E_REQUIRE_SESSION_EPOCH="${E2E_REQUIRE_SESSION_EPOCH:-1}"
export E2E_REQUIRE_PID="${E2E_REQUIRE_PID:-1}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export E2E_TIER="${E2E_TIER:-480p}"

KEYS_RAW="${E2E_REAL_GEOM_KEYS:-${E2E_REAL_RKS:-29,30,31,32}}"
# shellcheck disable=SC2206
KEYS=(${KEYS_RAW//,/ })

MATRIX_OUT="${E2E_MATRIX_OUT:-$REPO/build/e2e-artifacts-matrix}"
mkdir -p "$MATRIX_OUT"

echo "REAL_GEOM_MATRIX begin keys=${KEYS_RAW} cycles=${E2E_TRANSITION_CYCLES} content=${E2E_CONTENT}"
echo "REAL_GEOM_MATRIX require_measured=${E2E_REQUIRE_MEASURED_DELIVERY} require_session_epoch=${E2E_REQUIRE_SESSION_EPOCH}"
echo "REAL_GEOM_MATRIX out=${MATRIX_OUT}"
if [[ -n "${E2E_DAEMON_LOG:-}" ]]; then
  echo "REAL_GEOM_MATRIX E2E_DAEMON_LOG=${E2E_DAEMON_LOG} value_kind=caller-supplied"
else
  echo "REAL_GEOM_MATRIX E2E_DAEMON_LOG=(unset) — will try telemetry; if unprobed + require=1 → FAIL"
  echo "  Remediation (per key, before/while suite):"
  echo "    grep -E 'MEASURED_DELIVERY|measured_delivery=|desync_risk=|session_epoch=|PIPE_DESYNC' LIVE_LOG | tail -80 \\"
  echo "      > ${MATRIX_OUT}/daemon_snip.txt"
  echo "    export E2E_DAEMON_LOG=${MATRIX_OUT}/daemon_snip.txt"
  echo "  Or: E2E_DELIVERED_GEOM=WxH E2E_DESYNC_RISK=0 E2E_SESSION_EPOCH=P.S"
fi

PASS=0
FAIL=0
UNVER=0
SKIP=0
declare -a ROWS=()

for rk in "${KEYS[@]}"; do
  rk="${rk//[[:space:]]/}"
  rk="${rk#/library/metadata/}"
  [[ -z "$rk" ]] && continue
  if [[ ! "$rk" =~ ^[0-9]+$ ]]; then
    echo "REAL_GEOM_MATRIX_ROW rk=${rk} result=FAIL reason=bad_rating_key"
    FAIL=$((FAIL + 1))
    ROWS+=("rk=${rk} FAIL bad_key")
    continue
  fi
  echo "════════ REAL_GEOM_KEY rk=${rk} ════════"
  export PLEX_RATING_KEY="$rk"
  export PLEX_KEY="/library/metadata/${rk}"
  export E2E_OUT="${MATRIX_OUT}/rk_${rk}"
  mkdir -p "$E2E_OUT"

  set +e
  bash "$ROOT/run_cast_picker.sh"
  rc=$?
  set -e
  echo "REAL_GEOM_KEY_DONE rk=${rk} true rc=${rc}"

  case "$rc" in
    0)
      PASS=$((PASS + 1))
      ROWS+=("rk=${rk} PASS")
      echo "REAL_GEOM_MATRIX_ROW rk=${rk} result=PASS"
      ;;
    2)
      UNVER=$((UNVER + 1))
      FAIL=$((FAIL + 1))
      ROWS+=("rk=${rk} UNVERIFIED")
      echo "REAL_GEOM_MATRIX_ROW rk=${rk} result=UNVERIFIED (not a pass)"
      ;;
    77)
      SKIP=$((SKIP + 1))
      FAIL=$((FAIL + 1))
      ROWS+=("rk=${rk} SKIP-NOT-PASS")
      echo "REAL_GEOM_MATRIX_ROW rk=${rk} result=SKIP-NOT-PASS (not a pass)"
      ;;
    *)
      FAIL=$((FAIL + 1))
      ROWS+=("rk=${rk} FAIL rc=${rc}")
      echo "REAL_GEOM_MATRIX_ROW rk=${rk} result=FAIL rc=${rc}"
      ;;
  esac
done

echo "──────── REAL_GEOM_MATRIX_SUMMARY ────────"
for r in "${ROWS[@]}"; do
  echo "  $r"
done
echo "REAL_GEOM_MATRIX_RESULT pass=${PASS} fail=${FAIL} unverified=${UNVER} skip_not_pass=${SKIP} keys=${#KEYS[@]}"
echo "interesting_keys=29(624x352),32(720x480) force crop/pad/scale — 30 may be bank-sized real content"
echo "NOTE: Green Playwright != pixels/rows OK. Parent HDMI settles video claims."

if [[ "$FAIL" -gt 0 ]]; then
  echo "REAL_GEOM_MATRIX_RESULT=FAIL"
  exit 1
fi
echo "REAL_GEOM_MATRIX_RESULT=PASS"
exit 0
