#!/bin/sh
# Run ON device under claim. Token never echoed. Real PMS cast path.
set -e
OUT=/media/fat/misterplex/real_cast_v10
mkdir -p "$OUT"
CONF=/media/fat/misterplex/misterplex.conf
LOG=/media/fat/misterplex/misterplexd.log
TOKEN=$(grep -E "^[[:space:]]*PLEX_TOKEN=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=$(grep -E "^[[:space:]]*PLEX_BASE=" "$CONF" | head -1 | sed "s/^[^=]*=//" | tr -d "\r")
BASE=${BASE:-http://192.168.1.41:32400}
hp=${BASE#http://}; hp=${hp#https://}; hp=${hp%%/*}
ADDR=${hp%%:*}; PORT=${hp##*:}; [ "$PORT" = "$hp" ] && PORT=32400
echo "BASE=$BASE ADDR=$ADDR PORT=$PORT token_len=${#TOKEN}"
echo "CORENAME=$(cat /tmp/CORENAME 2>/dev/null)"
echo "live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk '{print $1}')"
echo "n_d=$(pidof misterplexd | wc -w)"
for p in $(pidof misterplexd); do tr "\0" " " < /proc/$p/cmdline; echo; done

# R0 identity
timeout 5 wget -q -O "$OUT/identity.xml" "$BASE/identity" && echo R0_identity_rc=0 || echo R0_identity_rc=$?
head -c 300 "$OUT/identity.xml"; echo
grep -q 'machineIdentifier="4edd44aa' "$OUT/identity.xml" && echo R0_VERDICT=HIT || echo R0_VERDICT=MISS

# R1 clients
timeout 8 wget -q -O "$OUT/clients.xml" "${BASE}/clients?X-Plex-Token=${TOKEN}" && echo R1_clients_rc=0 || echo R1_clients_rc=$?
grep -oE '(name|machineIdentifier|address|port|product)="[^"]*"' "$OUT/clients.xml" | head -20
if grep -q 'machineIdentifier="misterplex-dev"' "$OUT/clients.xml"; then echo R1_VERDICT=HIT; else echo R1_VERDICT=MISS; fi

# pick first movie key
timeout 12 wget -q -O "$OUT/items.xml" \
  "${BASE}/library/sections/1/all?X-Plex-Token=${TOKEN}&type=1&X-Plex-Container-Start=0&X-Plex-Container-Size=8" \
  && echo items_rc=0 || echo items_rc=$?
python3 /media/fat/misterplex/enum_items.py "$OUT/items.xml" | tee "$OUT/items_brief.txt"
KEY=$(python3 - <<'PY'
import re
xml=open("/media/fat/misterplex/real_cast_v10/items.xml").read()
m=re.search(r'key="(/library/metadata/\d+)"', xml)
print(m.group(1) if m else "")
PY
)
echo "SELECTED_KEY=$KEY"
if [ -z "$KEY" ]; then
  echo "R2_VERDICT=MISS reason=no_library_key"
  echo REAL_CAST_FAIL
  exit 2
fi

# clear log marker
echo "=== REAL_CAST_BEGIN $(date -u +%Y-%m-%dT%H:%M:%SZ) key=$KEY ===" >>"$LOG"

# stop any prior
timeout 3 wget -q -O /dev/null "http://127.0.0.1:3005/player/playback/stop" 2>/dev/null || true
sleep 1

# R2 playMedia — product-like params
ENC_KEY=$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("$KEY", safe=""))
PY
)
URL="http://127.0.0.1:3005/player/playback/playMedia?key=${ENC_KEY}&offset=0&commandID=real-cast-v10&protocol=http&address=${ADDR}&port=${PORT}&machineIdentifier=4edd44aac1de0b731553a3a187104ecd175571a0"
URL="${URL}&X-Plex-Token=${TOKEN}"
# also target header path via wget header if supported - busybox wget limited; query path is what prior lab used
rm -f "$OUT/play_body.xml" "$OUT/play_http_code.txt"
set +e
# product-like: Target-Client-Identifier header (empty target also accepted; header is real path)
timeout 25 curl -sS -m 20 -o "$OUT/play_body.xml" -w "%{http_code}"   -H "X-Plex-Target-Client-Identifier: misterplex-dev"   -H "X-Plex-Client-Identifier: lab-real-cast-v10"   "$URL" >"$OUT/play_http_code.txt"
play_rc=$?
set -e
echo play_curl_rc=$play_rc
echo play_http_code=$(cat "$OUT/play_http_code.txt" 2>/dev/null)
# redact body
sed 's/X-Plex-Token=[^&"]*/X-Plex-Token=REDACTED/g' "$OUT/play_body.xml" 2>/dev/null | head -c 600
echo
if grep -q 'Timeline' "$OUT/play_body.xml" 2>/dev/null; then echo R2_body_timeline=1; else echo R2_body_timeline=0; fi
sleep 2
echo "=== log after playMedia ==="
grep -E "REAL_CAST_BEGIN|playMedia|resolve|testsrc|refusing cast|bindMedia|ERROR|PLAY |session" "$LOG" | sed 's/X-Plex-Token=[^ &]*/X-Plex-Token=REDACTED/g' | tail -40

# classify resolve
if grep -E "REAL_CAST_BEGIN|playMedia ACK|resolve failed|test pattern|PLAY " "$LOG" | tail -20 | grep -q "resolve failed"; then
  echo R3_VERDICT=MISS
elif grep -E "PLAY testsrc" "$LOG" | tail -5 | grep -q testsrc; then
  # only fail if our session is testsrc
  if grep -A20 "REAL_CAST_BEGIN" "$LOG" | grep -q "PLAY testsrc"; then
    echo R3_VERDICT=MISS_testsrc_fallback
  else
    echo R3_VERDICT=CHECK
  fi
elif grep -A30 "REAL_CAST_BEGIN" "$LOG" | grep -qE "playMedia ACK|PLAY "; then
  echo R3_VERDICT=HIT_or_progress
else
  echo R3_VERDICT=UNKNOWN
fi

# R4/R5 wait and sample frames + timeline
sleep 8
echo "=== timeline poll ==="
timeout 5 curl -sS -m 5 -H "X-Plex-Target-Client-Identifier: misterplex-dev"   -o "$OUT/timeline1.xml" "http://127.0.0.1:3005/player/timeline/poll?wait=0&commandID=tl1" || true
sed 's/X-Plex-Token=[^&"]*/X-Plex-Token=REDACTED/g' "$OUT/timeline1.xml" 2>/dev/null | head -c 500
echo
grep -oE 'state="[^"]*"|time="[^"]*"|duration="[^"]*"|type="[^"]*"' "$OUT/timeline1.xml" 2>/dev/null | head -20

echo "=== frames snapshot1 ==="
grep "media: frames=" "$LOG" | tail -5

# CPU sample 20s during play
mpid=$(pidof misterplexd | awk '{print $1}')
echo mpid=$mpid
python3 /media/fat/misterplex/play_cpu_sample.py "$mpid" 20 | tee "$OUT/play_cpu.txt"

echo "=== frames snapshot2 ==="
grep "media: frames=" "$LOG" | tail -8
echo "=== log tail session ==="
grep -E "frames=|resolve|testsrc|ERROR|session end|PLAY |ffmpeg|refusing" "$LOG" | sed 's/X-Plex-Token=[^ &]*/X-Plex-Token=REDACTED/g' | tail -30

# stop
timeout 3 wget -q -O /dev/null "http://127.0.0.1:3005/player/playback/stop" 2>/dev/null || true
sleep 1
echo "=== after stop timeline ==="
timeout 5 curl -sS -m 5 -H "X-Plex-Target-Client-Identifier: misterplex-dev"   -o "$OUT/timeline_stop.xml" "http://127.0.0.1:3005/player/timeline/poll?wait=0&commandID=tlstop" || true
grep -oE 'state="[^"]*"|time="[^"]*"' "$OUT/timeline_stop.xml" 2>/dev/null | head -10

# re-check clients still there
timeout 8 wget -q -O "$OUT/clients_after.xml" "${BASE}/clients?X-Plex-Token=${TOKEN}" || true
grep -q 'machineIdentifier="misterplex-dev"' "$OUT/clients_after.xml" && echo R1_AFTER=HIT || echo R1_AFTER=MISS

echo CORENAME=$(cat /tmp/CORENAME)
echo live_md5=$(md5sum /media/fat/misterplex/bin/misterplexd | awk '{print $1}')
echo n_d=$(pidof misterplexd | wc -w)
grep PRESENT_PROFILE "$LOG" | tail -3
echo REAL_CAST_WINDOW_DONE
