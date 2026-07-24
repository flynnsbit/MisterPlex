#!/usr/bin/env bash
# Deploy static ARM misterplexd to MiSTer and restart.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN="$ROOT/build/arm/misterplexd"

if [[ ! -f "$BIN" ]]; then
  echo "Building arm misterplexd..."
  export PATH="${PATH}:/home/shawn/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin"
  make -C "$ROOT" arm-plexd
fi

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" \
  'mkdir -p /media/fat/misterplex/bin; killall -9 misterplexd 2>/dev/null || true; sleep 0.3'
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$BIN" "$USER@$HOST:/media/fat/misterplex/bin/misterplexd"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" bash -s <<'REMOTE'
set -e
chmod +x /media/fat/misterplex/bin/misterplexd
# Startup hook (idempotent)
HOOK=/media/fat/linux/_user-startup.sh
LINE='/media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id misterplex-183 --port 3005 --pms http://192.168.1.41:32400 >>/media/fat/misterplex/misterplexd.log 2>&1 &'
mkdir -p /media/fat/linux
touch "$HOOK"
if ! grep -q 'misterplex/bin/misterplexd' "$HOOK" 2>/dev/null; then
  printf '\n# MiSTerPlex companion + media\n%s\n' "$LINE" >>"$HOOK"
  echo "Added startup hook"
fi
: >>/media/fat/misterplex/misterplexd.log
# Truncate old log for this session
: >/media/fat/misterplex/misterplexd.log
nohup /media/fat/misterplex/bin/misterplexd --name MiSTerPlex --id misterplex-183 --port 3005 \
  --pms http://192.168.1.41:32400 \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
sleep 0.8
ps w | grep '[m]isterplexd' || true
wget -qO- http://127.0.0.1:3005/resources | head -c 300; echo
REMOTE
echo "Deployed misterplexd → $HOST"
