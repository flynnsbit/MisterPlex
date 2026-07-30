#!/usr/bin/env bash
# Restore a pre-deploy daemon and restart with canonical --id.
#
# Default source: misterplexd.prev-c2 (written atomically by deploy_misterplexd.sh
# immediately before each install).
#
# Override:
#   PREV_BIN=/media/fat/misterplex/backup/misterplexd.before-YYYYMMDDTHHMMSSZ
#   PREV_CONF=/media/fat/misterplex/backup/misterplex.conf.before-...  (optional)
#
# Does NOT restore Plex.rbf — pair core+daemon geometry yourself
# (320x240 bank1 0x30040000 vs 480p bank1 0x30080000). See docs/release.md.
#
# Mid-deploy hole (live binary missing, only prev remains): still works — copies
# PREV → BIN via stage+rename, then starts with --id misterplex-dev.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"

PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
PREV_BIN="${PREV_BIN:-/media/fat/misterplex/bin/misterplexd.prev-c2}"
PREV_CONF="${PREV_CONF:-}"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" bash -s -- \
  "${PMS_URL:-}" "$PLAYER_ID" "$PREV_BIN" "$PREV_CONF" <<'REMOTE'
set -euo pipefail
PMS_URL="${1:-}"
PLAYER_ID="${2:-misterplex-dev}"
PREV="${3:-/media/fat/misterplex/bin/misterplexd.prev-c2}"
PREV_CONF="${4:-}"
BIN=/media/fat/misterplex/bin/misterplexd
CONF=/media/fat/misterplex/misterplex.conf
LOG=/media/fat/misterplex/misterplexd.log

if [[ ! -f "$PREV" ]]; then
  echo "No backup at $PREV" >&2
  echo "Tried default prev-c2; set PREV_BIN= to a snapshot under /media/fat/misterplex/backup/" >&2
  ls -la /media/fat/misterplex/backup/ 2>/dev/null | head -20 || true
  exit 1
fi

want_md5=$(md5sum "$PREV" | awk '{print $1}')
echo "restore_source=$PREV want_md5=$want_md5"

# Soft stop first; -9 only if still up.
if pidof misterplexd >/dev/null 2>&1 || pidof ffmpeg >/dev/null 2>&1; then
  kill $(pidof misterplexd ffmpeg 2>/dev/null) 2>/dev/null || true
  sleep 0.4
fi
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill -9 "$p" 2>/dev/null || true
done
sleep 0.2

# Stage+rename so a failed restore never leaves an empty BIN if one existed.
stage="${BIN}.restore.$$"
cp -f "$PREV" "$stage"
chmod +x "$stage"
sync "$stage" 2>/dev/null || sync || true
mv -f "$stage" "$BIN"
got_md5=$(md5sum "$BIN" | awk '{print $1}')
if [[ "$got_md5" != "$want_md5" ]]; then
  echo "RESTORE_FAIL: md5 mismatch want=$want_md5 got=$got_md5" >&2
  exit 2
fi
echo "restored_md5=$got_md5"

if [[ -n "$PREV_CONF" ]]; then
  if [[ ! -f "$PREV_CONF" ]]; then
    echo "RESTORE_FAIL: PREV_CONF missing $PREV_CONF" >&2
    exit 1
  fi
  cts=$(date +%Y%m%dT%H%M%S)
  if [[ -f "$CONF" ]]; then
    cp -a "$CONF" "${CONF}.bak-pre-restore-${cts}"
  fi
  cp -f "$PREV_CONF" "$CONF"
  echo "restored_conf=$PREV_CONF"
fi

: >"$LOG"
pms_args=()
if [[ -n "$PMS_URL" ]]; then
  pms_args=(--pms "$PMS_URL")
fi
nohup "$BIN" --name MiSTerPlex --id "$PLAYER_ID" --port 3005 \
  --conf "$CONF" \
  "${pms_args[@]}" \
  >>"$LOG" 2>&1 &
sleep 0.8

ps_line=$(ps w | grep '[m]isterplexd' || true)
echo "daemon_ps=${ps_line:-NONE}"
if [[ -z "$ps_line" ]]; then
  echo "RESTORE_FAIL: daemon not running" >&2
  tail -n 40 "$LOG" 2>/dev/null || true
  exit 6
fi
# Exact --id token match
id_ok=0
set -- $ps_line
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--id" && -n "${2:-}" ]]; then
    [[ "$2" == "$PLAYER_ID" ]] && id_ok=1
    break
  fi
  if [[ "$1" == --id=* ]]; then
    [[ "${1#--id=}" == "$PLAYER_ID" ]] && id_ok=1
    break
  fi
  shift
done
if [[ "$id_ok" != "1" ]]; then
  echo "RESTORE_FAIL: DAEMON_ID_MISMATCH want=${PLAYER_ID} ps=${ps_line}" >&2
  exit 7
fi
echo "daemon_id_ok=${PLAYER_ID}"
echo "restored_from=$PREV"
md5sum "$BIN" "$PREV" || true
wget -qO- http://127.0.0.1:3005/resources 2>/dev/null | head -c 300 || true
echo
REMOTE

echo "Restored misterplexd on $HOST from ${PREV_BIN} (core unchanged — pair geometry yourself)"
