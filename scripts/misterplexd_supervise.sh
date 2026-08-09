#!/bin/sh
# MiSTerPlex daemon supervisor — respawn with backoff; loud EXIT logging.
# The FPGA RBF cannot start Linux processes; this ARM helper keeps misterplexd up.
set -eu
BIN="${MISTERPLEXD_BIN:-/media/fat/misterplex/bin/misterplexd}"
CONF="${MISTERPLEX_CONF:-/media/fat/misterplex/misterplex.conf}"
LOG="${MISTERPLEX_LOG:-/media/fat/misterplex/misterplexd.log}"
SUPLOG="${MISTERPLEX_SUPLOG:-/media/fat/misterplex/misterplexd_supervise.log}"
LAST="${MISTERPLEX_LAST:-/media/fat/misterplex/misterplexd.last}"
DEATH="${MISTERPLEX_DEATH:-/media/fat/misterplex/misterplexd.death}"
ID="${MISTERPLEX_ID:-misterplex}"
PORT="${MISTERPLEX_PORT:-3005}"
NAME="${MISTERPLEX_NAME:-MiSTerPlex}"
MIN_BACKOFF=2
MAX_BACKOFF=60
backoff=$MIN_BACKOFF

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sig_name() {
  case "$1" in
    1) echo SIGHUP ;;
    2) echo SIGINT ;;
    3) echo SIGQUIT ;;
    4) echo SIGILL ;;
    6) echo SIGABRT ;;
    7) echo SIGBUS ;;
    8) echo SIGFPE ;;
    9) echo SIGKILL ;;
    11) echo SIGSEGV ;;
    13) echo SIGPIPE ;;
    15) echo SIGTERM ;;
    *) echo "SIG_$1" ;;
  esac
}

mkdir -p "$(dirname "$SUPLOG")" "$(dirname "$LOG")"
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
  "$BIN" --name "$NAME" --id "$ID" --port "$PORT" --conf "$CONF" >>"$LOG" 2>&1 &
  child=$!
  echo "$(ts) SUPERVISE_CHILD pid=$child" >>"$SUPLOG"

  set +e
  wait "$child"
  st=$?
  set -e

  last_snap="(none)"
  death_snap="(none)"
  if [ -f "$LAST" ]; then
    last_snap=$(tr '\n' ' ' <"$LAST" | sed 's/[[:space:]]\+/ /g')
  fi
  if [ -f "$DEATH" ]; then
    death_snap=$(tr '\n' ' ' <"$DEATH" | sed 's/[[:space:]]\+/ /g')
  fi

  if [ "$st" -ge 128 ]; then
    sig=$((st - 128))
    sname=$(sig_name "$sig")
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st signal=$sig ($sname) — RESPAWN ${backoff}s last={$last_snap} death={$death_snap}" >>"$SUPLOG"
  else
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st exit_status=$st — RESPAWN ${backoff}s last={$last_snap} death={$death_snap}" >>"$SUPLOG"
  fi

  sleep "$backoff"
  if [ "$backoff" -lt "$MAX_BACKOFF" ]; then
    backoff=$((backoff * 2))
    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
  fi
done
