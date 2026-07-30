#!/usr/bin/env bash
# Stop the v3 fallback daemon and restart the DEV daemon if present.
# Does NOT overwrite files; only process control + launch.
set -euo pipefail

V3_ROOT="${MISTERPLEX_V3_ROOT:-/media/fat/misterplex_v3}"
DEV_ROOT="${MISTERPLEX_DEV_ROOT:-/media/fat/misterplex}"
DEV_BIN="$DEV_ROOT/bin/misterplexd"
DEV_CONF="$DEV_ROOT/misterplex.conf"
ID="${MISTERPLEX_ID:-misterplex-dev}"
PORT="${MISTERPLEX_PORT:-3005}"

echo "switch_to_dev: stopping any misterplexd / ffmpeg ..."
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill "$p" 2>/dev/null || true
done
sleep 0.5
for p in $(pidof misterplexd 2>/dev/null) $(pidof ffmpeg 2>/dev/null); do
  kill -9 "$p" 2>/dev/null || true
done
sleep 0.3
rm -f "$V3_ROOT/misterplexd.pid" 2>/dev/null || true

if [[ ! -x "$DEV_BIN" ]]; then
  echo "switch_to_dev: no dev binary at $DEV_BIN — stopped v3 only" >&2
  exit 1
fi
if [[ ! -f "$DEV_CONF" ]]; then
  echo "switch_to_dev: missing $DEV_CONF" >&2
  exit 1
fi

mkdir -p "$DEV_ROOT"
: >>"$DEV_ROOT/misterplexd.log"
nohup "$DEV_BIN" \
  --name MiSTerPlex \
  --id "$ID" \
  --port "$PORT" \
  --conf "$DEV_CONF" \
  >>"$DEV_ROOT/misterplexd.log" 2>&1 &
echo $! >"$DEV_ROOT/misterplexd.pid"
sleep 0.5
echo "switch_to_dev: started pid=$(cat "$DEV_ROOT/misterplexd.pid") log=$DEV_ROOT/misterplexd.log"
echo "switch_to_dev: load core /media/fat/_Utility/Plex.rbf (dev) from OSD if needed"
