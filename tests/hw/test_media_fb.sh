#!/usr/bin/env bash
# Hardware: playMedia → timeline playing → pause/resume/stop on live MiSTer.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
BASE="http://${HOST}:3005"

CURL=(curl -fsS --connect-timeout 5 --max-time 10)

echo "resources..."
"${CURL[@]}" "$BASE/resources" | grep -q MiSTerPlex

echo "play test.mp4..."
"${CURL[@]}" "$BASE/player/playback/playMedia?key=%2Fmedia%2Ffat%2Fmistercast%2Ftest.mp4&offset=0&commandID=1" \
  | grep -q fullScreenVideo
sleep 2
"${CURL[@]}" "$BASE/player/timeline/poll?commandID=2" | grep -q 'state="playing"'

echo "pause..."
"${CURL[@]}" "$BASE/player/playback/pause?commandID=3" >/dev/null
"${CURL[@]}" "$BASE/player/timeline/poll?commandID=4" | grep -q 'state="paused"'

echo "resume..."
"${CURL[@]}" "$BASE/player/playback/play?commandID=5" >/dev/null
"${CURL[@]}" "$BASE/player/timeline/poll?commandID=6" | grep -q 'state="playing"'

echo "stop (prePlayHold)..."
"${CURL[@]}" "$BASE/player/playback/stop?commandID=7" >/dev/null
"${CURL[@]}" "$BASE/player/timeline/poll?commandID=8" | grep -q 'location="navigation"'

echo "test_media_fb: OK on $HOST"
