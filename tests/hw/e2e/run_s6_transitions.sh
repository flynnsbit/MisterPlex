#!/usr/bin/env bash
# run_s6_transitions.sh — S6 N-loop transition stress (rd-review blocker).
#
# Runs the full UI transition set N times (default 10). ONE failure fails the
# suite — no average, no majority pass. Each FAIL names cycle + transition.
#
# Default content: synthetic lab tier (240p/rk via E2E_TIER) so this matches the
# parent-known-green path. For real-title N-loop use run_p7_real_title.sh or
# run_n_media_health.sh instead.
#
# Does NOT prove pixels. Grabber/HDMI is parent-only.
#
# Exit: 0 PASS | 1 FAIL | 78 INSUFFICIENT_EVIDENCE | 79 SESSION_INVALID | 77 SKIP-NOT-PASS
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-10}"
export E2E_TRANSITION_CONTINUE_ON_FAIL="${E2E_TRANSITION_CONTINUE_ON_FAIL:-1}"
export E2E_CLIENT_TRUTH="${E2E_CLIENT_TRUTH:-1}"
export E2E_REQUIRE_SESSION_RK="${E2E_REQUIRE_SESSION_RK:-1}"
export E2E_REQUIRE_REALTIME_RATE="${E2E_REQUIRE_REALTIME_RATE:-1}"
export E2E_TIER="${E2E_TIER:-240p}"
export E2E_CONTENT="${E2E_CONTENT:-synthetic}"
export E2E_P7="${E2E_P7:-0}"
export ASSERT_COMPANION="${ASSERT_COMPANION:-1}"
export E2E_ROBUSTNESS="${E2E_ROBUSTNESS:-1}"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-s6-transitions}"
mkdir -p "$E2E_OUT"

echo "S6_TRANSITIONS_RUN begin cycles=${E2E_TRANSITION_CYCLES} tier=${E2E_TIER} content=${E2E_CONTENT} out=${E2E_OUT}"
echo "S6_PREREG:"
echo "  PASS: TRANSITION_CYCLE_OK for each of N=${E2E_TRANSITION_CYCLES} (pause resume seek stop_recast play_idle_play)"
echo "  FAIL: any cycle RED — TRANSITION_CYCLE_FAIL cycle=K transition=NAME reason=..."
echo "  AGGREGATE: pass==N && fail==0 required; majority_pass_is_pass=0"
echo "  ATTR: failures name cycle + transition (e.g. transition_cycle_7_pause)"
echo "  TEARDOWN: our Playwright controller only — never kill user Plex tab"
echo "  BOUNDARY: control-plane only — NOT viewed pixels / playback quality"

node "$ROOT/race_taxonomy.js" || {
  echo "RACE_TAXONOMY_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}
node "$ROOT/client_truth.js" || {
  echo "CLIENT_TRUTH_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}

exec bash "$ROOT/run_cast_picker.sh" "$@"
