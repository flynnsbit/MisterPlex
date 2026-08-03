#!/usr/bin/env bash
# Hardware: video + /dev/MrAudio PCM path on live MiSTer.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
BASE="http://${HOST}:3005"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"

ssh_m() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$USER@$HOST" "$@"
}

echo "=== MrAudio present ==="
ssh_m 'test -c /dev/MrAudio && echo OK'

echo "=== mark log + play testsrc (video+sine) ==="
MARKER="audio-mraudio-gate-$$-$(date +%s)"
ssh_m "echo \"$MARKER\" >> /media/fat/misterplex/misterplexd.log"
curl -fsS "$BASE/player/playback/playMedia?key=testsrc&offset=0&commandID=70" >/dev/null
sleep 3
curl -fsS "$BASE/player/timeline/poll?commandID=71" | grep -q 'state="playing"'

echo "=== log shows audio=on after marker (not stale history) ==="
ok=0
for _ in 1 2 3 4 5; do
  LOG_TAIL=$(ssh_m "awk 'index(\$0,\"$MARKER\"){p=1;next} p' /media/fat/misterplex/misterplexd.log" 2>/dev/null || true)
  if printf '%s\n' "$LOG_TAIL" | grep -q "audio=on"; then
    ok=1
    break
  fi
  sleep 1
done
[[ $ok -eq 1 ]] || { echo "FAIL: no post-marker audio=on in log" >&2; ssh_m 'tail -20 /media/fat/misterplex/misterplexd.log'; exit 1; }

echo "=== MrAudio buffer has data (rptr/wptr) ==="
# Read status from device — empty/unparseable is FAIL, not a silent non-fatal pass.
ST=$(ssh_m 'cat /dev/MrAudio 2>/dev/null || true')
echo "MrAudio status: $ST"
if ! echo "$ST" | grep -qE 'wptr:|rptr:'; then
  echo "FAIL: MrAudio status missing wptr/rptr (cannot score PCM path)" >&2
  exit 1
fi

echo "=== play local test.mp4 with audio track attempt ==="
curl -fsS "$BASE/player/playback/stop?commandID=72" >/dev/null
sleep 0.3
curl -fsS "$BASE/player/playback/playMedia?key=%2Fmedia%2Ffat%2Fmistercast%2Ftest.mp4&offset=0&commandID=73" >/dev/null
sleep 2
curl -fsS "$BASE/player/timeline/poll?commandID=74" | grep -q 'state="playing"'
ssh_m 'grep -E "frames=|audio=" /media/fat/misterplex/misterplexd.log | tail -6'

curl -fsS "$BASE/player/playback/stop?commandID=75" >/dev/null
echo "test_audio_mraudio: OK on $HOST"
