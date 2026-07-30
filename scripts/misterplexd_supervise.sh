#!/bin/sh
# MiSTerPlex daemon supervisor — respawn with backoff; loud EXIT logging.
# Do NOT hide crashes: every restart is logged with status/signal.
set -eu
BIN=/media/fat/misterplex/bin/misterplexd
CONF=/media/fat/misterplex/misterplex.conf
LOG=/media/fat/misterplex/misterplexd.log
SUPLOG=/media/fat/misterplex/misterplexd_supervise.log
ID=misterplex-dev
PORT=3005
NAME=MiSTerPlex
MIN_BACKOFF=2
MAX_BACKOFF=60
backoff=$MIN_BACKOFF

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "$(ts) SUPERVISE_START bin=$BIN id=$ID conf=$CONF" >>"$SUPLOG"

while true; do
  if [ ! -x "$BIN" ]; then
    echo "$(ts) SUPERVISE_ERROR missing executable $BIN — sleep ${backoff}s" >>"$SUPLOG"
    sleep "$backoff"
    if [ "$backoff" -lt "$MAX_BACKOFF" ]; then
      backoff=$((backoff * 2))
      [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
    fi
    continue
  fi

  echo "$(ts) SUPERVISE_SPAWN id=$ID port=$PORT" >>"$SUPLOG"
  # Run in foreground of this shell so wait gets the real status.
  "$BIN" --name "$NAME" --id "$ID" --port "$PORT" --conf "$CONF" >>"$LOG" 2>&1 &
  child=$!
  echo "$(ts) SUPERVISE_CHILD pid=$child" >>"$SUPLOG"

  # wait captures exit; portable status decode
  set +e
  wait "$child"
  st=$?
  set -e

  # Decode: shell wait returns 128+N for signal N on many shells; also 0-255 exit
  if [ "$st" -ge 128 ]; then
    sig=$((st - 128))
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st WIFSIGNALED=1 signal=$sig (128+N) — RESPAWN backoff=${backoff}s" >>"$SUPLOG"
    echo "$(ts) misterplexd SUPERVISE: DIED signal=$sig wait_rc=$st — restarting in ${backoff}s" >>"$LOG"
  else
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st WIFSIGNALED=0 exit_status=$st — RESPAWN backoff=${backoff}s" >>"$SUPLOG"
    echo "$(ts) misterplexd SUPERVISE: DIED exit=$st — restarting in ${backoff}s" >>"$LOG"
  fi

  sleep "$backoff"
  if [ "$backoff" -lt "$MAX_BACKOFF" ]; then
    backoff=$((backoff * 2))
    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
  fi
done
