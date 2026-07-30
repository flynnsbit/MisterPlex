#!/usr/bin/env bash
# Read-mostly: copy live daemon+conf into /media/fat/misterplex/backup/ with a
# timestamp tag. Does NOT stop the daemon, does NOT replace binaries.
# Use before an authorised deploy so rollback has a known-good current snapshot
# (prev-c2 alone is overwritten by the next deploy).
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
TAG="${SNAPSHOT_TAG:-before-$(date -u +%Y%m%dT%H%M%SZ)}"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
  "$USER@$HOST" "TAG='$TAG' bash -s" <<'REMOTE'
set -euo pipefail
BIN=/media/fat/misterplex/bin/misterplexd
CONF=/media/fat/misterplex/misterplex.conf
BDIR=/media/fat/misterplex/backup
mkdir -p "$BDIR"
if [[ ! -f "$BIN" ]]; then
  echo "No live binary at $BIN" >&2
  exit 1
fi
bt="$BDIR/misterplexd.${TAG}"
btmp="${bt}.new.$$"
cp -f "$BIN" "$btmp"
sync "$btmp" 2>/dev/null || sync || true
mv -f "$btmp" "$bt"
echo "snapshot_bin=$bt"
md5sum "$bt"
if [[ -f "$CONF" ]]; then
  ct="$BDIR/misterplex.conf.${TAG}"
  ctmp="${ct}.new.$$"
  cp -f "$CONF" "$ctmp"
  sync "$ctmp" 2>/dev/null || sync || true
  mv -f "$ctmp" "$ct"
  echo "snapshot_conf=$ct"
  md5sum "$ct"
fi
# Also refresh prev-c2 to current live so default restore path matches today.
PREV=/media/fat/misterplex/bin/misterplexd.prev-c2
ptmp="${PREV}.new.$$"
cp -f "$BIN" "$ptmp"
sync "$ptmp" 2>/dev/null || sync || true
mv -f "$ptmp" "$PREV"
echo "prev_c2_refreshed=$PREV"
md5sum "$PREV"
ps w | grep '[m]isterplexd' || true
REMOTE

echo "Snapshot tag=$TAG on $HOST (daemon left running)"
