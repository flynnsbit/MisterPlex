#!/usr/bin/env bash
# Restore the pre-deploy daemon saved by deploy_misterplexd.sh (misterplexd.prev-c2),
# then restart it. Does NOT restore Plex.rbf — pair core+daemon geometry yourself
# (320x240 bank1 0x30040000 vs 480p bank1 0x30080000). See docs/release.md
# "Lab stable pair (v0.3.0)". Optional: PREV_BIN=/path/to/backup to override prev-c2.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"

PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
PREV_BIN="${PREV_BIN:-/media/fat/misterplex/bin/misterplexd.prev-c2}"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" bash -s -- "${PMS_URL:-}" "$PLAYER_ID" "$PREV_BIN" <<'REMOTE'
set -euo pipefail
PMS_URL="${1:-}"
PLAYER_ID="${2:-misterplex-dev}"
PREV="${3:-/media/fat/misterplex/bin/misterplexd.prev-c2}"
BIN=/media/fat/misterplex/bin/misterplexd
LOG=/media/fat/misterplex/misterplexd.log

if [[ ! -f "$PREV" ]]; then
  echo "No backup at $PREV" >&2
  exit 1
fi

# Soft stop first; -9 only if still up (same pattern as deploy_misterplexd.sh).
if pidof misterplexd >/dev/null 2>&1 || pidof ffmpeg >/dev/null 2>&1; then
  kill $(pidof misterplexd ffmpeg 2>/dev/null) 2>/dev/null || true
  sleep 0.4
fi
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill -9 "$p" 2>/dev/null || true
done
sleep 0.2
cp -f "$PREV" "$BIN"
chmod +x "$BIN"
: >"$LOG"
pms_args=()
if [[ -n "$PMS_URL" ]]; then
  pms_args=(--pms "$PMS_URL")
fi
nohup "$BIN" --name MiSTerPlex --id "$PLAYER_ID" --port 3005 \
  --conf /media/fat/misterplex/misterplex.conf \
  "${pms_args[@]}" \
  >>"$LOG" 2>&1 &
sleep 0.8
echo "restored_from=$PREV"
md5sum "$BIN" "$PREV" || true
echo "pidof_misterplexd=$(pidof misterplexd || true)"
ps w | grep '[m]isterplexd' || true
wget -qO- http://127.0.0.1:3005/resources | head -c 300
echo
REMOTE

echo "Restored previous misterplexd on $HOST (core unchanged — pair geometry yourself)"
