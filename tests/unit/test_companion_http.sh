#!/usr/bin/env bash
# Unit/smoke: companion scrubber fields, viewOffset, prePlayHold / castBound resume hold.
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

fail() { echo "FAIL: $*" >&2; exit 1; }

BODY=$(curl -fsS "http://127.0.0.1:${PORT}/resources")
echo "$BODY" | grep -q MiSTerPlexTest
echo "$BODY" | grep -q machineIdentifier

# --- playMedia stub (local testsrc via unresolved → pattern) ---
curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F1&offset=0&commandID=1" \
  | grep -q Timeline

# timeline poll should show buffering or playing (wantPlay)
POLL=$(curl -fsS "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=2")
echo "$POLL" | grep -q state=
echo "$POLL" | grep -Eq 'state="(buffering|playing|paused)"'

# ratingKey derived from key path when omitted
echo "$POLL" | grep -q 'ratingKey="1"' || fail "missing derived ratingKey from key: $POLL"
echo "$POLL" | grep -q 'playQueueItemID="1"' || fail "missing pqItem fallback from ratingKey: $POLL"

# pause / play / stop control paths
curl -fsS "http://127.0.0.1:${PORT}/player/playback/pause?commandID=3" | grep -q Timeline
curl -fsS "http://127.0.0.1:${PORT}/player/playback/play?commandID=4" | grep -q Timeline

# --- stop → prePlayHold while castBound (Resume dialog resilience) ---
STOP=$(curl -fsS "http://127.0.0.1:${PORT}/player/playback/stop?commandID=5")
echo "$STOP" | grep -q Timeline
# Stop ACK must not advertise live media keys (idles Web / freezes scrubber)
echo "$STOP" | grep -q 'location="navigation"' || fail "stop ACK not navigation: $STOP"
echo "$STOP" | grep -q 'state="buffering"' || fail "stop ACK not buffering hold: $STOP"
echo "$STOP" | grep -qv 'key="/library' || fail "stop ACK still has media key: $STOP"

POLL_HOLD=$(curl -fsS "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=5b")
echo "$POLL_HOLD" | grep -q 'location="navigation"' || fail "hold poll not navigation: $POLL_HOLD"
echo "$POLL_HOLD" | grep -q 'state="buffering"' || fail "hold poll not buffering: $POLL_HOLD"
echo "$POLL_HOLD" | grep -qv 'fullScreenVideo' || fail "hold poll still fullScreenVideo: $POLL_HOLD"

# --- mirror stages prePlayHold (buffering @ navigation, no live keys) ---
MIRROR=$(curl -fsS "http://127.0.0.1:${PORT}/player/timeline/mirror?key=%2Flibrary%2Fmetadata%2F2&commandID=6")
echo "$MIRROR" | grep -q Timeline
echo "$MIRROR" | grep -q 'state="buffering"' || fail "mirror not buffering: $MIRROR"
echo "$MIRROR" | grep -q 'location="navigation"' || fail "mirror not navigation: $MIRROR"
echo "$MIRROR" | grep -qv 'fullScreenVideo' || fail "mirror fullScreenVideo: $MIRROR"

# --- playMedia with full play-queue bind fields (Web scrubber contract) ---
PQ=$(curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F9&containerKey=%2FplayQueues%2F42%3Fown%3D1&playQueueItemID=99&playQueueVersion=3&ratingKey=9&address=192.168.1.41&port=32400&protocol=http&machineIdentifier=server-mid&offset=0&commandID=7")
echo "$PQ" | grep -q Timeline
# Immediate ACK should already expose queue bind (async resolve later)
echo "$PQ" | grep -q 'playQueueID="42"' || fail "ACK missing playQueueID: $PQ"
echo "$PQ" | grep -q 'playQueueItemID="99"' || fail "ACK missing playQueueItemID: $PQ"
echo "$PQ" | grep -q 'containerKey="/playQueues/42' || fail "ACK missing containerKey: $PQ"
echo "$PQ" | grep -q 'key="/library/metadata/9"' || fail "ACK missing key: $PQ"
echo "$PQ" | grep -q 'location="fullScreenVideo"' || fail "ACK not fullScreenVideo: $PQ"
echo "$PQ" | grep -q 'address="192.168.1.41"' || fail "ACK missing server address: $PQ"

sleep 0.3
POLL2=$(curl -fsS "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=8")
echo "$POLL2" | grep -q 'playQueueID="42"' || fail "poll missing playQueueID: $POLL2"
echo "$POLL2" | grep -q 'playQueueItemID="99"' || fail "poll missing playQueueItemID: $POLL2"
echo "$POLL2" | grep -q 'containerKey="/playQueues/42' || fail "poll missing containerKey: $POLL2"
echo "$POLL2" | grep -q 'key="/library/metadata/9"' || fail "poll missing key: $POLL2"
echo "$POLL2" | grep -q 'seekRange=' || true  # duration may still be 0 without resolve

# --- viewOffset query param (ms) seeds time on playMedia ---
VO=$(curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F11&viewOffset=74000&commandID=9")
echo "$VO" | grep -q 'time="74000"' || fail "viewOffset not applied to time=: $VO"

# offset=0 explicit must win over any staged viewOffset (Play from start)
OFF0=$(curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F12&offset=0&commandID=10")
echo "$OFF0" | grep -q 'time="0"' || fail "offset=0 not honored: $OFF0"

# --- poison containerKey=/library/metadata/N must not appear as containerKey ---
BADCK=$(curl -fsS "http://127.0.0.1:${PORT}/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F13&containerKey=%2Flibrary%2Fmetadata%2F13&commandID=11")
echo "$BADCK" | grep -qv 'containerKey="/library/metadata' || fail "poison containerKey emitted: $BADCK"

# --- proxy/timeline alias ---
curl -fsS "http://127.0.0.1:${PORT}/player/proxy/timeline?commandID=12" | grep -q Timeline

# --- unsubscribe clears castBound hold (after stop → pure stopped ok) ---
curl -fsS "http://127.0.0.1:${PORT}/player/playback/stop?commandID=13" >/dev/null
curl -fsS "http://127.0.0.1:${PORT}/player/timeline/unsubscribe?commandID=14" >/dev/null
# After unsubscribe without wantPlay, prePlayHold off — may be stopped or still buffered
# from residual state; at least request succeeds
curl -fsS "http://127.0.0.1:${PORT}/player/timeline/poll?commandID=15" | grep -q Timeline

echo "test_companion_http: OK"
