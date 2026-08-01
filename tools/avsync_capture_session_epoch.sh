#!/usr/bin/env bash
# Capture session_epoch from misterplexd log on device (parent/host via ssh).
# Absence is NO-DATA (rc=77), never 0.0.
#
# session_epoch uniquely IDs a stream session. drops/presents reset per stream
# (media_player.cpp). Any A/V claim spanning time must assert one epoch.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"

REMOTE='
set -e
pick=""
for f in /tmp/misterplexd.log /var/log/misterplexd.log /tmp/misterplex.log \
         /media/fat/misterplex/misterplexd.log /media/fat/misterplex_v2/misterplexd.log; do
  if [ -f "$f" ]; then pick=$f; break; fi
done
if [ -z "$pick" ]; then
  line=$(logread 2>/dev/null | grep "session_epoch=" | tail -n 1 || true)
  echo "log_src=logread"
else
  line=$(grep "session_epoch=" "$pick" 2>/dev/null | tail -n 1 || true)
  echo "log_src=$pick"
fi
echo "line=$line"
# Prefer supply_bucket / media lines
echo "$line" | sed -n "s/.*session_epoch=\([0-9.][0-9.]*\).*/session_epoch=\1/p" | tail -n 1
# Also surface fps_src if present on same or recent supply line
if [ -n "$pick" ]; then
  sl=$(grep "supply_bucket" "$pick" 2>/dev/null | tail -n 1 || true)
  echo "supply_line=$sl"
  echo "$sl" | sed -n "s/.*fps_src=\([^ ]*\).*/fps_src=\1/p" | tail -n 1
  echo "$sl" | sed -n "s/.*fps=\([^ ]*\).*/fps=\1/p" | tail -n 1
fi
'

echo "=== avsync_capture_session_epoch ==="
echo "host=$HOST src=DEFAULT_ASSUMED_or_env"
out=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  "${USER}@${HOST}" "sh -s" <<<"$REMOTE" 2>/dev/null || true)
printf '%s\n' "$out"
epoch=$(printf '%s\n' "$out" | sed -n 's/^session_epoch=//p' | tail -n 1)
if [[ -z "$epoch" ]]; then
  echo "session_epoch=NO-DATA src=measured"
  echo "VERDICT=UNSCORED rc=77 reason=session_epoch_absent"
  exit 77
fi
echo "session_epoch=$epoch src=measured"
fps_src=$(printf '%s\n' "$out" | sed -n 's/^fps_src=//p' | tail -n 1)
if [[ -n "$fps_src" ]]; then
  echo "fps_src=$fps_src src=measured_from_supply_bucket"
  echo "note=supply_gap/expected_frames use this rate; caller_supplied is ASSUMPTION not measurement"
else
  echo "fps_src=NO-DATA src=measured"
fi
echo "VERDICT=EPOCH_OK rc=0"
exit 0
