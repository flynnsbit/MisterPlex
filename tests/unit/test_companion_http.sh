#!/usr/bin/env bash
# User-path smoke: start misterplexd, hit /resources, playMedia, pause, stop.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/misterplexd"
make -C "$ROOT" plexd >/dev/null
PORT=13005
"$BIN" --name MiSTerPlexTest --port "$PORT" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5
BODY=$(curl -fsS "http://127.0.0.1:${PORT}/resources")
echo "$BODY" | grep -q MiSTerPlexTest
echo "$BODY" | grep -q machineIdentifier

# playMedia stub (local testsrc via unresolved → pattern)
curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F1&offset=0&commandID=1" \
  | grep -q Timeline

# timeline poll should show buffering or playing (wantPlay)
POLL=$(curl -fsS "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=2")
echo "$POLL" | grep -q state=
echo "$POLL" | grep -Eq 'state="(buffering|playing|paused)"'

# pause / play / stop control paths
curl -fsS "http://127.0.0.1:${PORT}/player/playback/pause?commandID=3" | grep -q Timeline
curl -fsS "http://127.0.0.1:${PORT}/player/playback/play?commandID=4" | grep -q Timeline
curl -fsS "http://127.0.0.1:${PORT}/player/playback/stop?commandID=5" | grep -q Timeline

# mirror stages prePlayHold (buffering @ navigation)
curl -fsS "http://127.0.0.1:${PORT}/player/timeline/mirror?key=%2Flibrary%2Fmetadata%2F2&commandID=6" \
  | grep -q Timeline

echo "test_companion_http: OK"
