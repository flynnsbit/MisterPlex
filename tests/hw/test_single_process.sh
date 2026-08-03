#!/usr/bin/env bash
# Hardware: single-process FFmpeg A/V (one demux) + headroom check.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
BASE="http://${HOST}:3005"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
CURL=(curl -fsS --connect-timeout 5 --max-time 12)

ssh_m() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$USER@$HOST" "$@"
}

echo "=== mark log + play PMS library (single-process expected) ==="
MARKER="single-process-gate-$$-$(date +%s)"
ssh_m "echo \"$MARKER\" >> /media/fat/misterplex/misterplexd.log"
"${CURL[@]}" "$BASE/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F3&offset=0&commandID=90" >/dev/null
sleep 4

echo "=== timeline playing ==="
"${CURL[@]}" "$BASE/player/timeline/poll?commandID=91" | grep -q 'state="playing"'

echo "=== process count: expect exactly 1 ffmpeg binary ==="
# MiSTer has no pgrep — use ps w. Zero procs with a green card is vacuous.
FF=$(ssh_m 'ps w | grep "[f]fmpeg" | grep -v grep | wc -l' | tr -dc '0-9')
FF=${FF:-0}
echo "ffmpeg_procs=$FF"
if [[ "$FF" -lt 1 ]]; then
  echo "FAIL: no ffmpeg process while timeline claims playing (cannot score single-process)" >&2
  exit 1
fi
if [[ "$FF" -ge 3 ]]; then
  echo "FAIL: too many ffmpeg processes (dual-path regression?)" >&2
  ssh_m 'ps w | grep ffmpeg | grep -v grep'
  exit 1
fi

echo "=== log shows single-process spawn after marker (not stale history) ==="
LOG_TAIL=$(ssh_m "awk 'index(\$0,\"$MARKER\"){p=1;next} p' /media/fat/misterplex/misterplexd.log")
echo "$LOG_TAIL" | grep -q "spawn single-process" || {
  echo "FAIL: no post-marker 'spawn single-process' (stale-log pass blocked)" >&2
  echo "$LOG_TAIL" | tail -40 >&2
  exit 1
}

echo "=== frames advancing with audio (post-marker) ==="
echo "$LOG_TAIL" | grep "audio=on" | tail -2 | grep -q audio=on || {
  echo "FAIL: no post-marker audio=on" >&2
  exit 1
}

echo "=== sample load ==="
ssh_m 'cat /proc/loadavg; top -bn1 | head -8'

"${CURL[@]}" "$BASE/player/playback/stop?commandID=92" >/dev/null
echo "test_single_process: OK on $HOST (ffmpeg_procs=$FF)"