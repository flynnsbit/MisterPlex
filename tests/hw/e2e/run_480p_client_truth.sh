#!/usr/bin/env bash
# run_480p_client_truth.sh — 480p-tier client-truth E2E (parameterised arm).
#
# Arms (E2E_480P_ARM or first CLI arg):
#   fullbleed | 27  — Bank480 FullBleed 624x480 (parent healthy reference)
#   bbb352    | 9   — BBB 624x352 (parent collapse / bitrate-stress case)
#   bbb       | 30  — long BBB bank
#   soak      | 8   — synthetic soak (default conf arm)
#
# Does NOT touch the device. Parent runs; agent-run ≠ evidence.
# Exit: 0 PASS | 1 FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS (never a pass)
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

ARM_IN="${1:-${E2E_480P_ARM:-fullbleed}}"
case "$(echo "$ARM_IN" | tr '[:upper:]' '[:lower:]')" in
  27|fullbleed|full-bleed|vres)
    ARM=fullbleed
    RK=27
    LABEL="FullBleed624x480_healthy"
    ;;
  9|bbb352|bbb_352|collapse)
    ARM=bbb352
    RK=9
    LABEL="BBB624x352_collapse_case"
    ;;
  30|bbb|bbb480)
    ARM=bbb
    RK=30
    LABEL="BBB_bank_long"
    ;;
  32|bbb720)
    ARM=bbb720
    RK=32
    LABEL="BBB720x480"
    ;;
  8|soak)
    ARM=soak
    RK=8
    LABEL="synthetic_soak"
    ;;
  *)
    echo "run_480p_client_truth: unknown arm=${ARM_IN}"
    echo "  use: fullbleed|27  bbb352|9  bbb|30  bbb720|32  soak|8"
    echo "CAST_PICKER_E2E_RESULT=FAIL"
    exit 1
    ;;
esac

export E2E_TIER=480p
export E2E_480P_ARM="$ARM"
export E2E_CONTENT="${E2E_CONTENT:-real}"
export E2E_CLIENT_TRUTH=1
export E2E_REQUIRE_REALTIME_RATE="${E2E_REQUIRE_REALTIME_RATE:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-10}"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-480p-${ARM}}"
# Pin ratingKey so discover cannot swap arms mid-matrix.
export PLEX_RATING_KEY="$RK"
export PLEX_KEY="/library/metadata/${RK}"
export E2E_CLIENT_RATING_KEY="$RK"

mkdir -p "$E2E_OUT"
echo "E2E_480P_RUN arm=${ARM} rk=${RK} label=${LABEL} cycles=${E2E_TRANSITION_CYCLES} out=${E2E_OUT}"
echo "E2E_480P_PREREG:"
echo "  fullbleed/rk=27 → expect CLIENT_RATE_OK near 1.0 when link healthy"
echo "  bbb352/rk=9     → may FAIL client_realtime_rate_low if collapse reproduces"
echo "  NEVER claim PASS on advance-only without CLIENT_RATE_OK"

exec bash "$ROOT/run_client_truth.sh"
