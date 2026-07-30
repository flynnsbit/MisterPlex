#!/usr/bin/env bash
# Launch the v0.3.0-era misterplexd from /media/fat/misterplex_v3/.
# Does not touch /media/fat/misterplex/ (dev install).
set -euo pipefail

ROOT="${MISTERPLEX_V3_ROOT:-/media/fat/misterplex_v3}"
BIN="$ROOT/bin/misterplexd"
CONF="$ROOT/misterplex.conf"
LOG="$ROOT/misterplexd.log"
ID="${MISTERPLEX_V3_ID:-misterplex-v3}"
PORT="${MISTERPLEX_V3_PORT:-3005}"
NAME="${MISTERPLEX_V3_NAME:-MiSTerPlex-v3}"

if [[ ! -x "$BIN" ]]; then
  echo "run_misterplexd_v3: missing executable $BIN" >&2
  exit 1
fi
if [[ ! -f "$CONF" ]]; then
  echo "run_misterplexd_v3: missing conf $CONF" >&2
  exit 1
fi

# Refuse to start if a different misterplexd is already bound to PORT.
if command -v ss >/dev/null 2>&1; then
  if ss -lnt 2>/dev/null | grep -q ":${PORT} "; then
    echo "run_misterplexd_v3: port $PORT already in use — stop the other daemon first" >&2
    echo "  tip: $ROOT/scripts/switch_to_v3.sh stops dev then starts v3" >&2
    exit 1
  fi
fi

mkdir -p "$ROOT"
: >>"$LOG"
nohup "$BIN" \
  --name "$NAME" \
  --id "$ID" \
  --port "$PORT" \
  --conf "$CONF" \
  >>"$LOG" 2>&1 &
echo $! >"$ROOT/misterplexd.pid"
sleep 0.5
if kill -0 "$(cat "$ROOT/misterplexd.pid")" 2>/dev/null; then
  echo "run_misterplexd_v3: started pid=$(cat "$ROOT/misterplexd.pid") log=$LOG"
else
  echo "run_misterplexd_v3: failed to stay up — see $LOG" >&2
  exit 1
fi
