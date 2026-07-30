#!/bin/sh
# MiSTerPlex daemon supervisor — respawn with backoff; loud EXIT logging.
# Do NOT hide crashes: every restart is logged with status/signal-by-name.
#
# Decode notes (busybox/ash + bash portable):
#   wait returns 0-255. Convention used here (and by bash):
#     st >= 128  → treated as signal (st-128); WIFSIGNALED approx
#     st < 128   → exit_status=st (includes SIGTERM handled → exit 0)
#   Core-dump bit is NOT available from shell wait — UNKNOWN always.
#   SIGKILL (9) cannot be caught inside the daemon; look for signal=9 here
#   and empty/stale misterplexd.death (no handler ran).
set -eu
BIN=/media/fat/misterplex/bin/misterplexd
CONF=/media/fat/misterplex/misterplex.conf
LOG=/media/fat/misterplex/misterplexd.log
SUPLOG=/media/fat/misterplex/misterplexd_supervise.log
LAST=/media/fat/misterplex/misterplexd.last
DEATH=/media/fat/misterplex/misterplexd.death
ID=misterplex-dev
PORT=3005
NAME=MiSTerPlex
MIN_BACKOFF=2
MAX_BACKOFF=60
backoff=$MIN_BACKOFF

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sig_name() {
  # Portable small table — numbers match Linux/arm.
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

  # Snapshot breadcrumbs that survive the process (best-effort).
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
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st WIFSIGNALED=1 signal=$sig signal_name=$sname core_dump=UNKNOWN — RESPAWN backoff=${backoff}s last={$last_snap} death={$death_snap}" >>"$SUPLOG"
    echo "$(ts) misterplexd SUPERVISE: DIED signal=$sig ($sname) wait_rc=$st — restarting in ${backoff}s" >>"$LOG"
  else
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st WIFSIGNALED=0 exit_status=$st core_dump=n/a — RESPAWN backoff=${backoff}s last={$last_snap} death={$death_snap}" >>"$SUPLOG"
    echo "$(ts) misterplexd SUPERVISE: DIED exit=$st — restarting in ${backoff}s" >>"$LOG"
  fi

  sleep "$backoff"
  if [ "$backoff" -lt "$MAX_BACKOFF" ]; then
    backoff=$((backoff * 2))
    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
  fi
done
