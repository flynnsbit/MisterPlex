#!/usr/bin/env bash
# test_cast_play_web.sh — the user's literal acceptance path, automated.
#
# Drives real Plex Web in real Chromium: pick MiSTerPlex in the player picker,
# press Play on a library item, dismiss any Resume dialog, and require that the
# daemon timeline leaves 0:00. Reproduces the reported symptom ("shows up as cast
# available but pressing play never casts / stays at 0:00") as a scored result.
#
# Exit codes: 0 pass, 1 fail, 2 refuse (no config), 77 skip (no browser/device).
# A skip is never reported as a pass.
#
# Env: PLEX_BASE PLEX_TOKEN PLEX_KEY (else ~/.config/misterplex/misterplex.conf),
#      PLEX_SERVER_ID, PLEX_HOME_USER (Plex Home installs), MISTER_HOST,
#      MISTERPLEX_NAME, CAST_RUNS (repeat count, default 1).
set -u
cd "$(dirname "$0")/../.."

CONF="${MISTERPLEX_CONF:-$HOME/.config/misterplex/misterplex.conf}"
[ -f "$CONF" ] || { echo "CAST_WEB_REFUSE: no config at $CONF" >&2; exit 2; }

if [ -z "${PLAYWRIGHT_MODULE:-}" ]; then
  for c in tests/hw/e2e/node_modules/playwright \
           "$PWD/../w-e2e/tests/hw/e2e/node_modules/playwright" \
           "$PWD/.worktrees/w-e2e/tests/hw/e2e/node_modules/playwright"; do
    [ -d "$c" ] && { PLAYWRIGHT_MODULE="$c"; break; }
  done
fi
[ -n "${PLAYWRIGHT_MODULE:-}" ] || { echo "CAST_WEB_SKIP: playwright not installed" >&2; exit 77; }
export PLAYWRIGHT_MODULE

HOST="${MISTER_HOST:-192.168.1.183}"
PORT="${MISTERPLEX_PORT:-3005}"
if ! curl -s -o /dev/null -m 6 "http://$HOST:$PORT/resources"; then
  echo "CAST_WEB_SKIP: no companion at $HOST:$PORT" >&2; exit 77
fi

runs="${CAST_RUNS:-1}"; pass=0; fail=0; skip=0
for i in $(seq 1 "$runs"); do
  node tests/hw/e2e/cast_play_web_e2e.js
  rc=$?
  case "$rc" in
    0) pass=$((pass+1));;
    1) fail=$((fail+1));;
    2) exit 2;;
    *) skip=$((skip+1));;
  esac
  curl -s -o /dev/null -m 8 "http://$HOST:$PORT/player/playback/stop?commandID=gate-$i"
  [ "$i" -lt "$runs" ] && sleep 5
done

echo "CAST_WEB pass=$pass fail=$fail skip=$skip denominator=$runs"
[ "$fail" -gt 0 ] && exit 1
[ "$pass" -gt 0 ] || exit 77
exit 0
