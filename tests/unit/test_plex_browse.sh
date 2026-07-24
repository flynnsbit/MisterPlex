#!/usr/bin/env bash
# Smoke: plex_browse.sh player commands against local misterplexd (curl only).
# No PMS token required for status/stop/play-with-test path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BROWSE="$ROOT/scripts/plex_browse.sh"
MENU="$ROOT/scripts/plex_menu.sh"
BIN="$ROOT/build/misterplexd"
chmod +x "$BROWSE" "$MENU" 2>/dev/null || true
make -C "$ROOT" plexd >/dev/null
PORT=13015
"$BIN" --name MiSTerPlexBrowseTest --port "$PORT" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5

fail() { echo "FAIL: $*" >&2; exit 1; }

# help exits 0
"$BROWSE" --help >/dev/null || fail "browse --help"

# status against local player
out=$("$BROWSE" --player "127.0.0.1:${PORT}" status) || fail "status"
echo "$out" | grep -q 'state=' || fail "status missing state: $out"

# play local key (resolve fails → test pattern; companion still ACKs)
out=$("$BROWSE" --player "127.0.0.1:${PORT}" play /library/metadata/99) || fail "play"
echo "$out" | grep -qE 'state=|key=' || fail "play ACK: $out"

# status after play should show media or buffering
sleep 0.3
out=$("$BROWSE" --player "127.0.0.1:${PORT}" status) || fail "status2"
echo "$out" | grep -q 'state=' || fail "status2: $out"

# seek
"$BROWSE" --player "127.0.0.1:${PORT}" seek 12000 || fail "seek"
out=$("$BROWSE" --player "127.0.0.1:${PORT}" status) || fail "status-seek"
# time may still be buffering at 12000
echo "$out" | grep -q 'time=' || fail "status after seek: $out"

# pause / resume / stop
"$BROWSE" --player "127.0.0.1:${PORT}" pause || fail "pause"
"$BROWSE" --player "127.0.0.1:${PORT}" resume || fail "resume"
"$BROWSE" --player "127.0.0.1:${PORT}" stop || fail "stop"

# menu script exists and --help works (non-interactive)
"$MENU" --help >/dev/null || fail "menu --help"

# servers with example conf (no token ok)
"$BROWSE" --conf "$ROOT/assets/misterplex.conf.example" servers | grep -q selected_base \
  || fail "servers"

echo "test_plex_browse: OK"
