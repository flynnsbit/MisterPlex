#!/usr/bin/env bash
# Deploy static ARM misterplexd to MiSTer and restart.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN="$ROOT/build/arm/misterplexd"

# Always let make decide. Guarding this with `if [[ ! -f "$BIN" ]]` meant that
# once the binary existed it was never rebuilt again, so every subsequent deploy
# silently shipped a stale daemon and "verified" fixes that were not on the box.
export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
make -C "$ROOT" arm-plexd
if [[ ! -f "$BIN" ]]; then
  echo "arm-plexd did not produce $BIN" >&2
  exit 1
fi

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  'mkdir -p /media/fat/misterplex/bin /media/fat/misterplex/scripts
   killall -9 misterplexd 2>/dev/null || true
   # Orphaned ffmpeg can inherit :3005 if CLOEXEC was missing — free the port
   fuser -k 3005/tcp 2>/dev/null || true
   killall -9 ffmpeg 2>/dev/null || true
   sleep 0.4
   rm -f /media/fat/misterplex/bin/misterplexd'
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$BIN" "$USER@$HOST:/media/fat/misterplex/bin/misterplexd"
# On-device browse / menu (Phase 4 UX)
if [[ -f "$ROOT/scripts/plex_browse.sh" ]]; then
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
    "$ROOT/scripts/plex_browse.sh" "$ROOT/scripts/plex_menu.sh" \
    "$USER@$HOST:/media/fat/misterplex/scripts/"
fi
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" bash -s <<'REMOTE'
set -e
chmod +x /media/fat/misterplex/bin/misterplexd
chmod +x /media/fat/misterplex/scripts/plex_browse.sh /media/fat/misterplex/scripts/plex_menu.sh 2>/dev/null || true
# Startup hook (idempotent)
HOOK=/media/fat/linux/_user-startup.sh
LINE='/media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id misterplex-183 --port 3005 --conf /media/fat/misterplex/misterplex.conf --pms http://192.168.1.41:32400 >>/media/fat/misterplex/misterplexd.log 2>&1 &'
mkdir -p /media/fat/linux /media/fat/misterplex
touch "$HOOK"
if ! grep -q 'misterplex/bin/misterplexd' "$HOOK" 2>/dev/null; then
  printf '\n# MiSTerPlex companion + media\n%s\n' "$LINE" >>"$HOOK"
  echo "Added startup hook"
fi
# Ensure conf exists (token optional — cast can supply transient tokens)
if [[ ! -f /media/fat/misterplex/misterplex.conf ]]; then
  cat >/media/fat/misterplex/misterplex.conf <<'CONF'
PLEX_BASE=http://192.168.1.41:32400
PLEX_HOST=192.168.1.41
# PLEX_TOKEN=
CONF
fi
: >/media/fat/misterplex/misterplexd.log
nohup /media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id misterplex-183 --port 3005 \
  --conf /media/fat/misterplex/misterplex.conf \
  --pms http://192.168.1.41:32400 \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 0.8
ps w | grep '[m]isterplexd' || true
wget -qO- http://127.0.0.1:3005/resources | head -c 300; echo
REMOTE
echo "Deployed misterplexd → $HOST"
