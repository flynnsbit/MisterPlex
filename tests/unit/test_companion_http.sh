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

# playMedia with play-queue bind fields (Web scrubber contract)
PQ=$(curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F9&containerKey=%2FplayQueues%2F42%3Fown%3D1&playQueueItemID=99&playQueueVersion=3&ratingKey=9&address=192.168.1.41&port=32400&protocol=http&machineIdentifier=server-mid&offset=0&commandID=7")
echo "$PQ" | grep -q Timeline
# After async bind, poll should expose queue fields while wantPlay
sleep 0.3
POLL2=$(curl -fsS "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=8")
echo "$POLL2" | grep -q 'playQueueID="42"' || { echo "FAIL missing playQueueID: $POLL2" >&2; exit 1; }
echo "$POLL2" | grep -q 'playQueueItemID="99"' || { echo "FAIL missing playQueueItemID: $POLL2" >&2; exit 1; }
echo "$POLL2" | grep -q 'containerKey="/playQueues/42' || { echo "FAIL missing containerKey: $POLL2" >&2; exit 1; }
echo "$POLL2" | grep -q 'key="/library/metadata/9"' || { echo "FAIL missing key: $POLL2" >&2; exit 1; }

echo "test_companion_http: OK"
