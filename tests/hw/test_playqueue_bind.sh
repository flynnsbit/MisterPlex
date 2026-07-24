#!/usr/bin/env bash
# Hardware: playMedia with play-queue fields → timeline scrubber bind.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
BASE="http://${HOST}:3005"

echo "=== playMedia with full queue bind ==="
# Simulate Plex Web cast URL fields
BODY=$(curl -fsS --get "$BASE/player/playback/playMedia" \
  --data-urlencode "key=/library/metadata/3" \
  --data-urlencode "containerKey=/playQueues/777?own=1" \
  --data-urlencode "playQueueItemID=555" \
  --data-urlencode "playQueueVersion=2" \
  --data-urlencode "ratingKey=3" \
  --data-urlencode "address=192.168.1.41" \
  --data-urlencode "port=32400" \
  --data-urlencode "protocol=http" \
  --data-urlencode "machineIdentifier=4edd44aac1de0b731553a3a187104ecd175571a0" \
  --data-urlencode "offset=0" \
  --data-urlencode "commandID=80")
echo "$BODY" | grep -q Timeline

sleep 2
POLL=$(curl -fsS "$BASE/player/timeline/poll?commandID=81")
echo "$POLL"
echo "$POLL" | grep -q 'playQueueID="777"'
echo "$POLL" | grep -q 'playQueueItemID="555"'
echo "$POLL" | grep -q 'containerKey="/playQueues/777'
echo "$POLL" | grep -q 'key="/library/metadata/3"'
echo "$POLL" | grep -Eq 'state="(playing|buffering)"'
echo "$POLL" | grep -q 'location="fullScreenVideo"'

curl -fsS "$BASE/player/playback/stop?commandID=82" >/dev/null
echo "test_playqueue_bind: OK on $HOST"
