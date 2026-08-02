#!/usr/bin/env bash
# run_control_plane_dod.sh — HDMI-blind definition-of-done half (Playwright + PMS).
#
# Settles: cast reachability + control plane (picker, session, pause/stop, companion).
# Does NOT settle: playback quality (~25% intermittent degrade), pixels on glass.
#
# Exit (w-avsync-aligned):
#   0  PASS
#   1  FAIL
#  78  INSUFFICIENT_EVIDENCE  (PMS unreachable / required axis NO-DATA)
#  79  SESSION_INVALID
#  77  SKIP-NOT-PASS / NO-DATA
#
# Required env (never commit lab IPs/tokens):
#   PLEX_BASE  PLEX_TOKEN_FILE  MISTER_HOST
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_CLIENT_TRUTH="${E2E_CLIENT_TRUTH:-1}"
export E2E_REQUIRE_PMS_CONTROL_PLANE="${E2E_REQUIRE_PMS_CONTROL_PLANE:-1}"
export E2E_REQUIRE_STALE_SESSION_CLEAN="${E2E_REQUIRE_STALE_SESSION_CLEAN:-1}"
export E2E_LEAN_BROWSER="${E2E_LEAN_BROWSER:-1}"
export E2E_REQUIRE_REALTIME_RATE="${E2E_REQUIRE_REALTIME_RATE:-1}"
export E2E_REQUIRE_SESSION_RK="${E2E_REQUIRE_SESSION_RK:-1}"
# Quality path OFF by default — intermittent 25% degrade; N=1 healthy is not quality PASS.
export E2E_REQUIRE_MEDIA_HEALTH="${E2E_REQUIRE_MEDIA_HEALTH:-0}"
export E2E_REQUIRE_DAEMON_EFFECTS="${E2E_REQUIRE_DAEMON_EFFECTS:-0}"
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-0}"
export E2E_REQUIRE_PID="${E2E_REQUIRE_PID:-0}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
# N=3 default for control (not quality power). Raise for stress; one fail still fails suite.
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-3}"
export E2E_CONTENT="${E2E_CONTENT:-fixture}"
export E2E_TIER="${E2E_TIER:-240p}"
export E2E_P7="${E2E_P7:-0}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export ASSERT_COMPANION="${ASSERT_COMPANION:-1}"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-control-plane-dod}"
mkdir -p "$E2E_OUT"

if [[ -z "${PLEX_BASE:-}" ]]; then
  echo "CONTROL_PLANE_DOD_UNCONFIGURED: set PLEX_BASE (local PMS). Not a pass."
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
fi
if [[ -z "${MISTER_HOST:-}" ]]; then
  echo "CONTROL_PLANE_DOD_UNCONFIGURED: set MISTER_HOST (no lab-IP default). Not a pass."
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
fi

if [[ -n "${E2E_CLIENT_RATING_KEY:-}" && -z "${PLEX_RATING_KEY:-}" && -z "${PLEX_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_CLIENT_RATING_KEY}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
fi

echo "CONTROL_PLANE_DOD_RUN begin cycles=${E2E_TRANSITION_CYCLES} tier=${E2E_TIER} out=${E2E_OUT}"
echo "QUALITY_POLICY=VERIFY_CONTROL_NOT_QUALITY (parent ~25% intermittent degrade; N=1 healthy misses ~75%)"
echo "PRE_REGISTER PASS: picker exact + companion + PMS session rk + pause/stop gone + TEARDOWN_OK"
echo "PRE_REGISTER FAIL: any control assert red; INSUFFICIENT rc=78 if PMS NO-DATA; SESSION_INVALID rc=79 on rk swap"
echo "PRE_REGISTER NEVER: claim playback quality; soft-pass 77/78; kill user Plex tab; encode lab IPs"

node "$ROOT/evidence_codes.js" || {
  echo "EVIDENCE_CODES_SELFCHECK_FAIL"
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
}
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
