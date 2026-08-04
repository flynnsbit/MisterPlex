#!/usr/bin/env bash
# Deploy static ARM misterplexd to MiSTer and restart.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN="$ROOT/build/arm/misterplexd"
PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
PMS_URL="${PLEX_BASE:-${PMS_URL:-}}"

# Always let make decide. Guarding this with `if [[ ! -f "$BIN" ]]` meant that
# once the binary existed it was never rebuilt again, so every subsequent deploy
# silently shipped a stale daemon and "verified" fixes that were not on the box.
export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
make -C "$ROOT" arm-plexd
if [[ ! -f "$BIN" ]]; then
  echo "arm-plexd did not produce $BIN" >&2
  exit 1
fi

# Live install root: prefer misterplex_v2 when that tree is what is actually
# running (Sweep 114 trap: shipping to misterplex/bin while the supervisor
# launches misterplex_v2/bin looks like success and deploys nothing).
# Override with MISTERPLEX_ROOT=/media/fat/misterplex if needed.
REMOTE_ROOT_DETECT=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  'if [ -n "$(pidof misterplexd 2>/dev/null)" ]; then
     tr "\0" "\n" < /proc/$(pidof misterplexd | awk "{print \$1}")/cmdline 2>/dev/null | head -1
   fi
   if [ -x /media/fat/misterplex_v2/bin/misterplexd ]; then echo V2_PRESENT; fi
   if [ -x /media/fat/misterplex/bin/misterplexd ]; then echo V1_PRESENT; fi' || true)
if [[ -n "${MISTERPLEX_ROOT:-}" ]]; then
  REMOTE_ROOT="$MISTERPLEX_ROOT"
elif echo "$REMOTE_ROOT_DETECT" | grep -q 'misterplex_v2'; then
  REMOTE_ROOT=/media/fat/misterplex_v2
elif echo "$REMOTE_ROOT_DETECT" | grep -q 'V2_PRESENT'; then
  REMOTE_ROOT=/media/fat/misterplex_v2
else
  REMOTE_ROOT=/media/fat/misterplex
fi
echo "deploy_misterplexd: REMOTE_ROOT=$REMOTE_ROOT (detect: ${REMOTE_ROOT_DETECT//$'\n'/ | })"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "ROOT='$REMOTE_ROOT' bash -s" <<'REMOTE'
set -e
mkdir -p "$ROOT/bin" "$ROOT/scripts"
if [ -f "$ROOT/bin/misterplexd" ]; then
  cp -f "$ROOT/bin/misterplexd" "$ROOT/bin/misterplexd.prev-busyloopfix"
fi
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill -9 "$p" 2>/dev/null || true
done
sleep 0.4
rm -f "$ROOT/bin/misterplexd"
REMOTE
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$BIN" \
  "$USER@$HOST:$REMOTE_ROOT/bin/misterplexd"
# On-device browse / menu (Phase 4 UX)
if [[ -f "$ROOT/scripts/plex_browse.sh" ]]; then
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
    "$ROOT/scripts/plex_browse.sh" "$ROOT/scripts/plex_menu.sh" \
    "$USER@$HOST:$REMOTE_ROOT/scripts/"
fi
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  "PLAYER_ID='$PLAYER_ID' PMS_URL='$PMS_URL' ROOT='$REMOTE_ROOT' bash -s" <<'REMOTE'
set -e
chmod +x "$ROOT/bin/misterplexd"
chmod +x "$ROOT/scripts/plex_browse.sh" "$ROOT/scripts/plex_menu.sh" 2>/dev/null || true
# Startup hook (idempotent) — only append if no misterplexd hook exists at all.
HOOK=/media/fat/linux/_user-startup.sh
PMS_ARG=""
if [[ -n "${PMS_URL:-}" ]]; then
  PMS_ARG=" --pms ${PMS_URL}"
fi
CONF="$ROOT/misterplex.conf"
# Fall back to v1 conf if this tree has none (v2 often shares settings).
if [[ ! -f "$CONF" && -f /media/fat/misterplex/misterplex.conf ]]; then
  CONF=/media/fat/misterplex/misterplex.conf
fi
LINE="$ROOT/bin/misterplexd --name MiSTerPlex --id ${PLAYER_ID:-misterplex-dev} --port 3005 --conf ${CONF}${PMS_ARG} >>$ROOT/misterplexd.log 2>&1 &"
mkdir -p /media/fat/linux "$ROOT"
touch "$HOOK"
if ! grep -q 'misterplexd' "$HOOK" 2>/dev/null; then
  printf '\n# MiSTerPlex companion + media\n%s\n' "$LINE" >>"$HOOK"
  echo "Added startup hook"
fi
if [[ ! -f "$CONF" ]]; then
  cat >"$CONF" <<'CONF'
# Set this to your Plex Media Server, for example:
# PLEX_BASE=http://YOUR-PLEX-SERVER:32400
# PLEX_TOKEN=
CONF
  if [[ -n "${PMS_URL:-}" ]]; then
    printf 'PLEX_BASE=%s\n' "$PMS_URL" >>"$CONF"
  fi
fi
: >"$ROOT/misterplexd.log"
nohup "$ROOT/bin/misterplexd" --name MiSTerPlex --id "${PLAYER_ID:-misterplex-dev}" --port 3005 \
  --conf "$CONF" ${PMS_ARG} \
  >>"$ROOT/misterplexd.log" 2>&1 &
sleep 0.8
ps w | grep '[m]isterplexd' || true
# Prove the live binary path matches what we just installed.
if [ -n "$(pidof misterplexd 2>/dev/null)" ]; then
  LIVE=$(tr '\0' '\n' < /proc/$(pidof misterplexd | awk '{print $1}')/cmdline | head -1)
  echo "live_cmdline=$LIVE"
  case "$LIVE" in
    "$ROOT/bin/misterplexd") echo "deploy path OK" ;;
    *) echo "WARNING: live binary is not $ROOT/bin/misterplexd" >&2 ;;
  esac
fi
wget -qO- http://127.0.0.1:3005/resources | head -c 300; echo
REMOTE
echo "Deployed misterplexd → $HOST:$REMOTE_ROOT/bin/misterplexd"
