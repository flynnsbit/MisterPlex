#!/usr/bin/env bash
# run_n_media_health.sh — N-loop transitions + per-cycle media health (S6).
#
# Parent intermittency (same core/daemon/conf/clip):
#   COLLAPSED supply_ratio=0.72 drift=+133  vs  HEALTHY supply_ratio=0.99 drift=-30
# UI advance alone is a false pass for the collapsed case.
#
# Gates per cycle (ONE failure fails the suite — no average):
#   - client UI transitions (pause/resume/seek/stop/replay)
#   - supply_ratio >= 0.90 (derived: above collapsed 0.72, under healthy 0.99)
#   - |av_drift_ms| <= 75 (above |healthy|~30, below collapsed +133)
#   - clock= field present (value av-lock is NON_DISCRIMINATING literal — ERROR 20)
#   - daemon pid stable (change → INVALID; counters re-zero on respawn)
#   - COMPANION_INVARIANT primary = PMS under test
#   - TEARDOWN_OK our controller only (never kill user Plex tab)
#
# Media fields need either:
#   - deployed daemon with /player/telemetry (av_drift_ms/supply_ratio/pid), OR
#   - E2E_DAEMON_LOG= host snip of media:/supply_bucket lines (parent-fed; no ssh)
# Unprobed media health is FAIL, never soft-pass.
#
# Exit: 0 PASS | 1 FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_CLIENT_TRUTH="${E2E_CLIENT_TRUTH:-1}"
export E2E_REQUIRE_MEDIA_HEALTH="${E2E_REQUIRE_MEDIA_HEALTH:-1}"
export E2E_MEDIA_MIN_SUPPLY_RATIO="${E2E_MEDIA_MIN_SUPPLY_RATIO:-0.90}"
export E2E_MEDIA_MAX_ABS_DRIFT_MS="${E2E_MEDIA_MAX_ABS_DRIFT_MS:-75}"
export E2E_REQUIRE_REALTIME_RATE="${E2E_REQUIRE_REALTIME_RATE:-1}"
export E2E_REQUIRE_SESSION_RK="${E2E_REQUIRE_SESSION_RK:-1}"
export E2E_REQUIRE_PID="${E2E_REQUIRE_PID:-1}"
export E2E_REQUIRE_LEDGER="${E2E_REQUIRE_LEDGER:-1}"
export E2E_REQUIRE_DAEMON_EFFECTS="${E2E_REQUIRE_DAEMON_EFFECTS:-0}"
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-0}"
export E2E_REQUIRE_SESSION_EPOCH="${E2E_REQUIRE_SESSION_EPOCH:-0}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-10}"
export E2E_TRANSITION_CONTINUE_ON_FAIL="${E2E_TRANSITION_CONTINUE_ON_FAIL:-1}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export E2E_CONTENT="${E2E_CONTENT:-real}"
export E2E_TIER="${E2E_TIER:-480p}"
export E2E_P7="${E2E_P7:-1}"
export E2E_REAL_ALLOW_BANK_GEOM="${E2E_REAL_ALLOW_BANK_GEOM:-1}"
export ASSERT_COMPANION="${ASSERT_COMPANION:-1}"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-n-media-health}"
mkdir -p "$E2E_OUT"

if [[ -n "${E2E_CLIENT_RATING_KEY:-}" && -z "${PLEX_RATING_KEY:-}" && -z "${PLEX_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_CLIENT_RATING_KEY}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
fi

echo "N_MEDIA_HEALTH_RUN begin cycles=${E2E_TRANSITION_CYCLES} tier=${E2E_TIER} rk=${PLEX_RATING_KEY:-auto} out=${E2E_OUT}"
echo "N_MEDIA_HEALTH_PREREG:"
echo "  PASS: N/${E2E_TRANSITION_CYCLES} cycles each MEDIA_HEALTH_OK + UI transitions + COMPANION_INVARIANT + TEARDOWN_OK"
echo "  FAIL: any cycle supply_ratio<0.90 | |drift|>75 | UI transition fail | wrong companion"
echo "  INVALID: daemon pid change mid-suite (respawn re-zero counters) — never flattering score"
echo "  UNPROBED media health → FAIL (not skip). Provide telemetry deploy or E2E_DAEMON_LOG="
echo "  clock=av-lock value is NON_DISCRIMINATING literal (ERROR 20); field presence still required"
echo "  ONE fail in N fails suite — no average. majority_pass_is_pass=0"
echo "  NEVER kill user long-lived Plex tab; TEARDOWN only our Playwright controller"

node "$ROOT/media_health.js" || {
  echo "MEDIA_HEALTH_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}
node "$ROOT/client_truth.js" || {
  echo "CLIENT_TRUTH_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}

exec bash "$ROOT/run_cast_picker.sh" "$@"
