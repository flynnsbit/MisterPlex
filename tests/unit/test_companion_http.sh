#!/usr/bin/env bash
# User-path smoke: start misterplexd, hit /resources, stop.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/misterplexd"
make -C "$ROOT" plexd >/dev/null
PORT=13005
"$BIN" --name MiSTerPlexTest --port "$PORT" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.4
BODY=$(curl -fsS "http://127.0.0.1:${PORT}/resources")
echo "$BODY" | grep -q MiSTerPlexTest
echo "$BODY" | grep -q machineIdentifier
# playMedia stub
curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F1&offset=0&commandID=1" \
  | grep -q Timeline
# timeline poll
curl -fsS "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=2" | grep -q state=
echo "test_companion_http: OK"
