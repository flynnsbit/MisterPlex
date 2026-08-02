#!/usr/bin/env bash
# run_pms_control_plane.sh — HDMI-independent DoD half via Playwright + PMS HTTP.
#
# BOUNDARY (always printed by the suite too):
#   Proves cast/session/transcode CONTROL PLANE only.
#   CANNOT prove a single correct pixel reached the screen.
#   Green here is NOT a viewed-pixel PASS.
#
# Scores:
#   - MiSTer in Select Player (exact; ghost reject)
#   - PMS /status/sessions: playing + correct ratingKey; pause; gone on stop
#   - PMS /transcode/sessions: speed not collapsed (parent: healthy≈19.8 vs collapsed=0)
#   - Stale hygiene: leftover sessions/transcoders after stop → FAIL
#   - TEARDOWN_OK our Playwright controller only (never kill user Plex tab)
#
# Lean Chromium default (workstation CPU-contended with Plex Transcoder).
#
# Env (required — never commit lab addresses/tokens):
#   PLEX_BASE   e.g. http://127.0.0.1:32400 when PMS is local Docker
#   PLEX_TOKEN or PLEX_TOKEN_FILE
#   MISTER_HOST (cast target companion; default tooling host ok)
#
# Exit: 0 PASS | 1 FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS (never a pass)
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_CLIENT_TRUTH="${E2E_CLIENT_TRUTH:-1}"
export E2E_REQUIRE_PMS_CONTROL_PLANE="${E2E_REQUIRE_PMS_CONTROL_PLANE:-1}"
export E2E_REQUIRE_STALE_SESSION_CLEAN="${E2E_REQUIRE_STALE_SESSION_CLEAN:-1}"
export E2E_PMS_MIN_TRANSCODE_SPEED="${E2E_PMS_MIN_TRANSCODE_SPEED:-0.5}"
export E2E_PMS_TRANSCODE_ALLOW_EMPTY="${E2E_PMS_TRANSCODE_ALLOW_EMPTY:-1}"
export E2E_LEAN_BROWSER="${E2E_LEAN_BROWSER:-1}"
export E2E_REQUIRE_REALTIME_RATE="${E2E_REQUIRE_REALTIME_RATE:-1}"
export E2E_REQUIRE_SESSION_RK="${E2E_REQUIRE_SESSION_RK:-1}"
export E2E_REQUIRE_MEDIA_HEALTH="${E2E_REQUIRE_MEDIA_HEALTH:-0}"
export E2E_REQUIRE_DAEMON_EFFECTS="${E2E_REQUIRE_DAEMON_EFFECTS:-0}"
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-0}"
export E2E_REQUIRE_SESSION_EPOCH="${E2E_REQUIRE_SESSION_EPOCH:-0}"
export E2E_REQUIRE_PID="${E2E_REQUIRE_PID:-0}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-5}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export E2E_CONTENT="${E2E_CONTENT:-real}"
export E2E_TIER="${E2E_TIER:-480p}"
export E2E_P7="${E2E_P7:-0}"
export E2E_REAL_ALLOW_BANK_GEOM="${E2E_REAL_ALLOW_BANK_GEOM:-1}"
export ASSERT_COMPANION="${ASSERT_COMPANION:-1}"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-pms-control-plane}"
mkdir -p "$E2E_OUT"

if [[ -z "${PLEX_BASE:-}" ]]; then
  echo "PMS_CONTROL_PLANE_UNCONFIGURED: set PLEX_BASE (local PMS URL). Not a pass."
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
fi

if [[ -n "${E2E_CLIENT_RATING_KEY:-}" && -z "${PLEX_RATING_KEY:-}" && -z "${PLEX_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_CLIENT_RATING_KEY}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
fi

echo "PMS_CONTROL_PLANE_RUN begin cycles=${E2E_TRANSITION_CYCLES} rk=${PLEX_RATING_KEY:-auto} out=${E2E_OUT}"
echo "CONTROL_PLANE_ONLY: Playwright+PMS prove cast/session/transcode. CANNOT prove pixels. Green ≠ viewed-pixel PASS."
echo "PMS_CONTROL_PLANE_PREREG:"
echo "  PASS: MiSTer in picker; /status/sessions playing rk=expected; pause reflected;"
echo "        stop → session gone; /transcode/sessions speed>=0.5 (or empty direct-play);"
echo "        stale clean; TEARDOWN_OK our-controller only"
echo "  FAIL: session missing/wrong rk; pause not on PMS; leftover after stop;"
echo "        transcoder speed=0 collapsed class (parent complete=0 progress=68.6 speed=0)"
echo "  NEVER: score HDMI pixels; kill user Plex tab; soft-pass rc=77 as green"

node "$ROOT/pms_control_plane.js" || {
  echo "PMS_CONTROL_PLANE_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}
node "$ROOT/client_truth.js" || {
  echo "CLIENT_TRUTH_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}

exec bash "$ROOT/run_cast_picker.sh" "$@"
