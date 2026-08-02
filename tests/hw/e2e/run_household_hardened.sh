#!/usr/bin/env bash
# run_household_hardened.sh — parent entry for HDMI-blind DoD weight.
#
# Bundles:
#   1) COMPANION_INVARIANT (friendlyName sort fragility — names the offending server)
#   2) N-cycle transitions (default 10; one fail fails suite; majority ≠ pass)
#   3) Real / P7 content path (not flash fixture) when E2E_CONTENT=real
#   4) MEASURED_DELIVERY require=1 + GEOM_TRIPLE (request/library/measured)
#      Parent class: requested_pms=624x480 library_media=624x480 → measured=624x350
#   5) PMS control-plane scorers + TEARDOWN_OK our-controller only
#
# BOUNDARY: Playwright/PMS control plane CANNOT prove pixels. HDMI-USB is separate.
# Agent-run is NOT evidence — parent runs this and captures true rc=$?
#
# Required env (never commit lab IPs/tokens):
#   PLEX_BASE  PLEX_TOKEN_FILE  MISTER_HOST
#
# Exit: 0 PASS | 1 FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS (never a pass)
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
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-1}"
export E2E_REQUIRE_SESSION_EPOCH="${E2E_REQUIRE_SESSION_EPOCH:-0}"
export E2E_REQUIRE_MEDIA_HEALTH="${E2E_REQUIRE_MEDIA_HEALTH:-0}"
export E2E_REQUIRE_DAEMON_EFFECTS="${E2E_REQUIRE_DAEMON_EFFECTS:-0}"
export E2E_REQUIRE_PID="${E2E_REQUIRE_PID:-0}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-10}"
export E2E_CONTENT="${E2E_CONTENT:-real}"
export E2E_TIER="${E2E_TIER:-480p}"
export E2E_P7="${E2E_P7:-1}"
export E2E_REAL_ALLOW_BANK_GEOM="${E2E_REAL_ALLOW_BANK_GEOM:-1}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export ASSERT_COMPANION="${ASSERT_COMPANION:-1}"
# Optional name pin (no IP): EXPECT_COMPANION_FRIENDLYNAME="MiSTerPlex Studio"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-household-hardened}"
mkdir -p "$E2E_OUT"

if [[ -z "${PLEX_BASE:-}" ]]; then
  echo "HOUSEHOLD_HARDENED_UNCONFIGURED: set PLEX_BASE (local PMS). Not a pass."
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
fi
if [[ -z "${MISTER_HOST:-}" ]]; then
  echo "HOUSEHOLD_HARDENED_UNCONFIGURED: set MISTER_HOST (no lab-IP default). Not a pass."
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
fi

if [[ -n "${E2E_CLIENT_RATING_KEY:-}" && -z "${PLEX_RATING_KEY:-}" && -z "${PLEX_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_CLIENT_RATING_KEY}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
fi

echo "HOUSEHOLD_HARDENED_RUN begin cycles=${E2E_TRANSITION_CYCLES} content=${E2E_CONTENT} p7=${E2E_P7} out=${E2E_OUT}"
echo "CONTROL_PLANE_ONLY: Playwright+PMS. CANNOT prove pixels. Green ≠ viewed-pixel PASS."
echo "HOUSEHOLD_HARDENED_PREREG:"
echo "  PASS: COMPANION_INVARIANT names selected fn; N/${E2E_TRANSITION_CYCLES} TRANSITION_CYCLE_OK;"
echo "        MEASURED_DELIVERY_OK delivery_basis=measured + GEOM_TRIPLE logged;"
echo "        real/P7 title (not flash); TEARDOWN_OK our-controller only"
echo "  FAIL: wrong companion (diagnostic names offending friendlyName);"
echo "        any cycle fail; measured unprobed when require=1;"
echo "        expectGeom=library_media while measured differs (624x350 class)"
echo "  NEVER: majority of N as pass; kill user Plex tab; score library as delivery"

node "$ROOT/measured_delivery.js" || {
  echo "MEASURED_DELIVERY_SELFCHECK_FAIL"
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
