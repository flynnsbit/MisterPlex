#!/usr/bin/env bash
# run_client_truth.sh — Playwright DoD half: Plex Web CLIENT observations only.
#
# Scores: cast picker, play/pause/seek/stop as the *client* sees them (UI clock +
# PMS /status/sessions ratingKey). NEVER scores misterplexd av-lock/drops/smoothness
# (parent ERROR 20: av-lock is an unconditional string literal).
#
# Real BBB ladder (section 2, measured when present): rk 28–32 default pin 30 or auto.
# Does NOT touch the device. Leaves suite teardown to force idle (daily driver safe).
#
# Exit: 0 PASS | 1 FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS (never a pass)
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_CLIENT_TRUTH="${E2E_CLIENT_TRUTH:-1}"
export E2E_REQUIRE_DAEMON_EFFECTS="${E2E_REQUIRE_DAEMON_EFFECTS:-0}"
export E2E_REQUIRE_SESSION_RK="${E2E_REQUIRE_SESSION_RK:-1}"
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-0}"
export E2E_REQUIRE_SESSION_EPOCH="${E2E_REQUIRE_SESSION_EPOCH:-0}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-10}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export E2E_REQUIRE_PID="${E2E_REQUIRE_PID:-0}"
export E2E_CONTENT="${E2E_CONTENT:-real}"
export E2E_TIER="${E2E_TIER:-480p}"
export E2E_P7="${E2E_P7:-1}"
export E2E_REAL_ALLOW_BANK_GEOM="${E2E_REAL_ALLOW_BANK_GEOM:-1}"
export E2E_REQUIRE_REALTIME_RATE="${E2E_REQUIRE_REALTIME_RATE:-1}"
export E2E_REALTIME_MIN_RATIO="${E2E_REALTIME_MIN_RATIO:-0.75}"
export E2E_REALTIME_MAX_RATIO="${E2E_REALTIME_MAX_RATIO:-1.35}"
export ASSERT_COMPANION="${ASSERT_COMPANION:-1}"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-client-truth}"
mkdir -p "$E2E_OUT"

# Optional pin: real BBB ladder. Empty → Contract3 auto-discover (long BBB preferred).
if [[ -n "${E2E_CLIENT_RATING_KEY:-}" && -z "${PLEX_RATING_KEY:-}" && -z "${PLEX_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_CLIENT_RATING_KEY}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
elif [[ -z "${PLEX_RATING_KEY:-}" && -z "${PLEX_KEY:-}" && -n "${E2E_P7_RATING_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_P7_RATING_KEY}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
fi

echo "CLIENT_TRUTH_RUN begin cycles=${E2E_TRANSITION_CYCLES} tier=${E2E_TIER} rk=${PLEX_RATING_KEY:-auto} out=${E2E_OUT}"
echo "CLIENT_TRUTH_PREREG:"
echo "  PASS: MiSTerPlex in picker; UI advances; media/wall ratio in [0.75,1.35];"
echo "        pause frozen; seek near+advances; stop idle; rk stable; COMPANION_INVARIANT=PASS"
echo "  FAIL: starved-class rate (parent collapse ratio~0.467 still advances timeline);"
echo "        UI stuck / seek miss / cast missing / wrong primary companion"
echo "  INVALID: ratingKey changes mid-window — never score as data"
echo "  NEVER_SCORE: daemon av-lock, drops, smoothness, A/V sync"
echo "  RATE_DERIVATION: min=0.75 from starved audio_s/wall_s=0.467 vs healthy=0.993"
echo "  IDLE_END: suite force-stops; daily driver must return to static logo"

# Red-before-green pure proofs (no device)
node "$ROOT/client_truth.js" || {
  echo "CLIENT_TRUTH_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}

exec bash "$ROOT/run_cast_picker.sh" "$@"
