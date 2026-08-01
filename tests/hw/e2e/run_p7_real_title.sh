#!/usr/bin/env bash
# run_p7_real_title.sh — P7 real full-frame title E2E (Playwright control plane).
#
# Closes the *suite* half of rd-review P7: real title (not flash fixture), measured
# selection, correlated GEOM/measured=, CAPTURE_WINDOW for parent HDMI, N transitions.
# Viewed pixels remain parent-only — green here does NOT close P7 promotion.
#
# ERROR 12: clear daemon log BEFORE PLAY (or set E2E_P7_CLEAR_WAIT_SEC and clear
# during the wait), then export E2E_DAEMON_LOG snip + E2E_LOG_CLEARED_BEFORE_CAST=1.
#
# Exit: 0 PASS | 1 FAIL | 2 UNVERIFIED | 77 SKIP-NOT-PASS (never a pass)
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../.." && pwd)"
cd "$ROOT" || exit 77

export E2E_P7=1
export E2E_CONTENT="${E2E_CONTENT:-real}"
export E2E_TIER="${E2E_TIER:-480p}"
export E2E_TRANSITIONS="${E2E_TRANSITIONS:-1}"
export E2E_TRANSITION_CYCLES="${E2E_TRANSITION_CYCLES:-10}"
export E2E_REQUIRE_MEASURED_DELIVERY="${E2E_REQUIRE_MEASURED_DELIVERY:-1}"
export E2E_REQUIRE_SESSION_EPOCH="${E2E_REQUIRE_SESSION_EPOCH:-1}"
export E2E_REQUIRE_PID="${E2E_REQUIRE_PID:-1}"
export E2E_PLXD_FRAMES_VOID="${E2E_PLXD_FRAMES_VOID:-1}"
export E2E_P7_HOLD_SEC="${E2E_P7_HOLD_SEC:-45}"
export E2E_P7_CAPTURE_HOLD="${E2E_P7_CAPTURE_HOLD:-1}"
# BBB / real keys: prefer long real title; parent may pin.
# rk=30 BBB 624x480 1200s | rk=32 720x480 | rk=29 624x352 | rk=27 full-bleed
if [[ -z "${PLEX_RATING_KEY:-}" && -z "${PLEX_KEY:-}" ]]; then
  export PLEX_RATING_KEY="${E2E_P7_RATING_KEY:-30}"
  export PLEX_KEY="/library/metadata/${PLEX_RATING_KEY}"
fi
# Real BBB at bank library_media is allowed under E2E_P7 (not a flash fixture).
export E2E_REAL_ALLOW_BANK_GEOM="${E2E_REAL_ALLOW_BANK_GEOM:-1}"

export E2E_OUT="${E2E_OUT:-$REPO/build/e2e-p7}"
mkdir -p "$E2E_OUT"

echo "P7_RUN begin ratingKey=${PLEX_RATING_KEY:-} cycles=${E2E_TRANSITION_CYCLES} hold_sec=${E2E_P7_HOLD_SEC}"
echo "P7_RUN out=${E2E_OUT}"
echo "P7_RUN artifacts: ${E2E_OUT}/p7_cast_manifest.json ${E2E_OUT}/p7_events.jsonl ${E2E_OUT}/e2e_run_id.txt"
if [[ -n "${E2E_DAEMON_LOG:-}" ]]; then
  echo "P7_RUN E2E_DAEMON_LOG=${E2E_DAEMON_LOG} cleared_flag=${E2E_LOG_CLEARED_BEFORE_CAST:-0}"
else
  echo "P7_RUN E2E_DAEMON_LOG=(unset) — MEASURED_DELIVERY require=1 will FAIL unless telemetry has fields"
  echo "  Recipe:"
  echo "    1) E2E_P7_CLEAR_WAIT_SEC=30 ./tests/hw/e2e/run_p7_real_title.sh   # pause before play"
  echo "    2) during wait: truncate LIVE misterplexd.log; export E2E_LOG_CLEARED_BEFORE_CAST=1"
  echo "    3) after CAST_WINDOW_CLOSE: snip GEOM/MEASURED lines → export E2E_DAEMON_LOG=..."
fi
echo "P7_BOUNDARY: suite PASS ≠ viewed pixels. Parent HDMI in CAPTURE_WINDOW_* closes P7."

exec bash "$ROOT/run_cast_picker.sh" "$@"
