#!/usr/bin/env bash
# run_pms_delivery_cast.sh — Playwright cast + PMS delivery observation (HDMI-blind).
#
# Settles (Plex's view):
#   MiSTer in Select Player, cast starts, /status/sessions playing + ratingKey,
#   delivered_geom + hasTranscodeSession from PMS session document,
#   pause/stop reflected, TEARDOWN_OK.
#
# Does NOT settle: pixels on glass. PASS_SCOPE=control_plane+pms_delivery only.
#
# Bitrate ladder: suite OBSERVES PMS; it does not set maxVideoBitrate (daemon conf).
# Parent configures request bitrate on device, then runs this with expects:
#   E2E_PMS_EXPECT_GEOM=312x240 E2E_PMS_EXPECT_HAS_TRANSCODE=0   # parent 397 class
#   E2E_PMS_EXPECT_GEOM=624x480 E2E_PMS_EXPECT_HAS_TRANSCODE=1   # parent 2000 class (if TS present)
#
# For observe-while-parent-casts (no Playwright): run_pms_session_observe.sh
#
# Exit: 0 PASS | 1 FAIL | 78 INSUFFICIENT_EVIDENCE | 79 SESSION_INVALID | 77 SKIP-NOT-PASS
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_CLIENT_TRUTH="${E2E_CLIENT_TRUTH:-1}"
export E2E_REQUIRE_PMS_CONTROL_PLANE="${E2E_REQUIRE_PMS_CONTROL_PLANE:-1}"
export E2E_REQUIRE_PMS_DELIVERY="${E2E_REQUIRE_PMS_DELIVERY:-1}"
export E2E_REQUIRE_STALE_SESSION_CLEAN="${E2E_REQUIRE_STALE_SESSION_CLEAN:-1}"
export E2E_PMS_TRANSCODE_ALLOW_EMPTY="${E2E_PMS_TRANSCODE_ALLOW_EMPTY:-1}"
export E2E_LEAN_BROWSER="${E2E_LEAN_BROWSER:-1}"
export E2E_REQUIRE_REALTIME_RATE="${E2E_REQUIRE_REALTIME_RATE:-1}"
export E2E_REQUIRE_SESSION_RK="${E2E_REQUIRE_SESSION_RK:-1}"
export E2E_REQUIRE_MEDIA_HEALTH="${E2E_REQUIRE_MEDIA_HEALTH:-0}"
export E2E_REQUIRE_DAEMON_EFFECTS="${E2E_REQUIRE_DAEMON_EFFECTS:-0}"
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-0}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-3}"
export E2E_CONTENT="${E2E_CONTENT:-fixture}"
export E2E_TIER="${E2E_TIER:-480p}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export ASSERT_COMPANION="${ASSERT_COMPANION:-1}"
export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-pms-delivery}"
mkdir -p "$E2E_OUT"

if [[ -z "${PLEX_BASE:-}" || -z "${MISTER_HOST:-}" ]]; then
  echo "UNCONFIGURED: export PLEX_BASE and MISTER_HOST (local only). Not a pass."
  echo "CAST_PICKER_E2E_RESULT=FAIL"
  exit 1
fi

if [[ -n "${E2E_CLIENT_RATING_KEY:-}" && -z "${PLEX_RATING_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_CLIENT_RATING_KEY}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
fi

echo "PMS_DELIVERY_CAST begin tier=${E2E_TIER} rk=${PLEX_RATING_KEY:-auto} out=${E2E_OUT}"
echo "EXPECT geom=${E2E_PMS_EXPECT_GEOM:-observe} hasTS=${E2E_PMS_EXPECT_HAS_TRANSCODE:-observe}"
echo "BOUNDARY: PMS+Playwright control/delivery — NOT pixels. Green ≠ viewed-pixel PASS."
echo "CAN: observe TranscodeSession presence + delivered WxH from /status/sessions across parent bitrate arms."
echo "CANNOT: set maxVideoBitrate from Web (daemon conf); prove glass pixels."

node "$ROOT/evidence_codes.js" || exit 1
node "$ROOT/pms_control_plane.js" || exit 1

exec bash "$ROOT/run_cast_picker.sh" "$@"
