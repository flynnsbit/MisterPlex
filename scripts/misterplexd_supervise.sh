#!/bin/sh
# MiSTerPlex daemon supervisor — respawn with backoff; loud EXIT logging.
# Do NOT hide crashes: every restart is logged with status/signal-by-name.
#
# Prefer tools/death_capture_supervisor (waitpid WIF* + /proc sample) when the
# binary is present next to misterplexd. Falls back to shell wait otherwise.
#
# Decode notes (busybox/ash + bash portable shell path):
#   wait returns 0-255. Convention used here (and by bash):
#     st >= 128  → treated as signal (st-128); WIFSIGNALED approx
#     st < 128   → exit_status=st (includes SIGTERM handled → exit 0)
#   Core-dump bit is NOT available from shell wait — UNKNOWN always.
#   SIGKILL (9) cannot be caught inside the daemon; look for signal=9 here
#   and empty/stale misterplexd.death (no handler ran).
#
# OOM correlation (device lane): after SUPERVISE_EXIT with signal=9 or sudden
# death + high VmHWM in proc_sample.last, run on device:
#   dmesg -T | grep -iE 'killed process|out of memory|oom-kill|Memory cgroup'
# Positive look like:
#   "Out of memory: Killed process 1234 (misterplexd)"
#   "oom-kill:constraint=CONSTRAINT_NONE,...task=misterplexd..."
set -eu
BIN=/media/fat/misterplex/bin/misterplexd
CAP=/media/fat/misterplex/bin/death_capture_supervisor
CONF=/media/fat/misterplex/misterplex.conf
LOG=/media/fat/misterplex/misterplexd.log
SUPLOG=/media/fat/misterplex/misterplexd_supervise.log
LAST=/media/fat/misterplex/misterplexd.last
DEATH=/media/fat/misterplex/misterplexd.death
PROCSNAP=/media/fat/misterplex/proc_sample.last
ID=misterplex-dev
PORT=3005
NAME=MiSTerPlex
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

# Sample /proc while child lives (background). Survives as last-known mem/oom.
sample_loop() {
  _pid=$1
  while kill -0 "$_pid" 2>/dev/null; do
    _score="?"
    _adj="?"
    _rss="?"
    _hwm="?"
    if [ -r "/proc/$_pid/oom_score" ]; then
      _score=$(tr -d ' \n' <"/proc/$_pid/oom_score" 2>/dev/null || echo "?")
    fi
    if [ -r "/proc/$_pid/oom_score_adj" ]; then
      _adj=$(tr -d ' \n' <"/proc/$_pid/oom_score_adj" 2>/dev/null || echo "?")
    fi
    if [ -r "/proc/$_pid/status" ]; then
      _rss=$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$_pid/status" 2>/dev/null || echo "?")
      _hwm=$(awk '/^VmHWM:/ {print $2; exit}' "/proc/$_pid/status" 2>/dev/null || echo "?")
    fi
    echo "$(ts) pid=$_pid oom_score=$_score oom_score_adj=$_adj VmRSS_kB=$_rss VmHWM_kB=$_hwm" >"$PROCSNAP"
    sleep 1
  done
}

snap_one_line() {
  _f=$1
  if [ -f "$_f" ]; then
    tr '\n' ' ' <"$_f" | sed 's/[[:space:]]\+/ /g'
  else
    echo "(absent)"
  fi
}

log_tail_one_line() {
  if [ -f "$LOG" ]; then
    tail -n 20 "$LOG" 2>/dev/null | tr '\n' '|' | sed 's/[[:space:]]\+/ /g'
  else
    echo "(log-absent)"
  fi
}

echo "$(ts) SUPERVISE_START bin=$BIN id=$ID conf=$CONF cap=${CAP}" >>"$SUPLOG"

# Preferred path: C supervisor (real waitpid WIF* + jsonl). One-shot respawn loop here.
if [ -x "$CAP" ]; then
  echo "$(ts) SUPERVISE_MODE=death_capture_supervisor" >>"$SUPLOG"
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
    echo "$(ts) SUPERVISE_SPAWN mode=cap id=$ID port=$PORT backoff=${backoff}s" >>"$SUPLOG"
    set +e
    "$CAP" --once \
      --dir /media/fat/misterplex \
      --log "$LOG" \
      --label misterplexd \
      --death "$DEATH" \
      --last "$LAST" \
      -- "$BIN" --name "$NAME" --id "$ID" --port "$PORT" --conf "$CONF" >>"$LOG" 2>&1
    st=$?
    set -e
    # Cap already appended death_capture.log; mirror a short line into SUPLOG.
    if [ -f /media/fat/misterplex/death_capture.log ]; then
      tail -n 1 /media/fat/misterplex/death_capture.log >>"$SUPLOG" || true
    else
      echo "$(ts) SUPERVISE_EXIT mode=cap wait_rc=$st (no death_capture.log)" >>"$SUPLOG"
    fi
    echo "$(ts) misterplexd SUPERVISE: DIED cap_rc=$st — restarting in ${backoff}s" >>"$LOG"
    sleep "$backoff"
    if [ "$backoff" -lt "$MAX_BACKOFF" ]; then
      backoff=$((backoff * 2))
      [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
    fi
  done
fi

echo "$(ts) SUPERVISE_MODE=shell_wait (cap binary missing)" >>"$SUPLOG"

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
  sample_loop "$child" &
  sampler=$!

  set +e
  wait "$child"
  st=$?
  set -e
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true

  last_snap=$(snap_one_line "$LAST")
  death_snap=$(snap_one_line "$DEATH")
  proc_snap=$(snap_one_line "$PROCSNAP")
  log_snap=$(log_tail_one_line)

  death_freshness="n/a"
  if [ "$st" -ge 128 ]; then
    sig=$((st - 128))
    sname=$(sig_name "$sig")
    if [ "$sig" -eq 9 ]; then
      case "$death_snap" in
        *signal=9*) death_freshness="UNEXPECTED_handler_ran" ;;
        *) death_freshness="stale_or_absent_expected" ;;
      esac
    else
      case "$death_snap" in
        "(absent)"|"(empty)"|"") death_freshness="absent" ;;
        *) death_freshness="present" ;;
      esac
    fi
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st WIFSIGNALED=1 signal=$sig signal_name=$sname core_dump=UNKNOWN death_freshness=$death_freshness — RESPAWN backoff=${backoff}s proc={$proc_snap} last={$last_snap} death={$death_snap} log_tail={$log_snap}" >>"$SUPLOG"
    echo "$(ts) misterplexd SUPERVISE: DIED signal=$sig ($sname) wait_rc=$st — restarting in ${backoff}s" >>"$LOG"
  else
    echo "$(ts) SUPERVISE_EXIT pid=$child wait_rc=$st WIFSIGNALED=0 exit_status=$st core_dump=n/a death_freshness=$death_freshness — RESPAWN backoff=${backoff}s proc={$proc_snap} last={$last_snap} death={$death_snap} log_tail={$log_snap}" >>"$SUPLOG"
    echo "$(ts) misterplexd SUPERVISE: DIED exit=$st — restarting in ${backoff}s" >>"$LOG"
  fi

  sleep "$backoff"
  if [ "$backoff" -lt "$MAX_BACKOFF" ]; then
    backoff=$((backoff * 2))
    [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
  fi
done
