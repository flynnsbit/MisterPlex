#!/bin/sh
# misterplexd_supervise.sh — durable single-instance supervisor for misterplexd.
#
# Install to: $ROOT/bin/misterplexd_supervise.sh  (ROOT = live pair root,
# normally /media/fat/misterplex_v2). Boot hook must invoke THIS path, never
# the v1 root and never a bare misterplexd (parent 2026-07-31 cold-boot defect).
#
# Contract:
#   - ROOT derived from this script's location (…/bin/misterplexd_supervise.sh)
#   - BIN=$ROOT/bin/misterplexd  CONF=$ROOT/misterplex.conf
#   - single-instance: flock -n /tmp/misterplexd_supervise.lock (fd 9)
#   - HEALTHY_SECS=120 backoff reset after sustained healthy run
#   - resume_stopped_main: argv0 must be EXACTLY /media/fat/MiSTer (no substring)
#   - never identify misterplexd by cmdline substring (flock trap)
#   - On every child exit, log death/last/si_*/log_tail so handled-SIGTERM→rc=0
#     is distinguishable from a genuine voluntary exit (w-cpu rc=0 lane).
#
# Shell wait is NOT full waitpid WIF*:
#   st < 128  → WIFEXITED_approx exit_status=st  (handled SIGTERM → often 0)
#   st >= 128 → WIFSIGNALED_approx signal=(st-128)
# Do not treat rc=0 as "daemon decided to die" without death=[signal= si_pid=].

set -u

SCRIPT=$0
case "$SCRIPT" in
  /*) ;;
  *) SCRIPT=$(pwd)/$SCRIPT ;;
esac
BIN_DIR=$(dirname "$SCRIPT")
ROOT=${MISTERPLEX_ROOT:-$(dirname "$BIN_DIR")}
BIN=$ROOT/bin/misterplexd
CONF=$ROOT/misterplex.conf
LOG=$ROOT/misterplexd.log
SUPLOG=$ROOT/misterplexd_supervise.log
LAST=$ROOT/misterplexd.last
DEATH=$ROOT/misterplexd.death
NAME=${MISTERPLEX_NAME:-MiSTerPlex}
ID=${MISTERPLEX_ID:-misterplex-dev}
PORT=${MISTERPLEX_PORT:-3005}
LOCK=${MISTERPLEX_SUPERVISE_LOCK:-/tmp/misterplexd_supervise.lock}
HEALTHY_SECS=${MISTERPLEX_HEALTHY_SECS:-120}

mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SUPERVISE_ALREADY_HELD lock=$LOCK root=$ROOT" >>"$SUPLOG" 2>/dev/null || true
  exit 0
fi

backoff=2
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sig_name() {
  case "$1" in
    2) echo SIGINT ;;
    9) echo SIGKILL ;;
    15) echo SIGTERM ;;
    *) echo "SIG_$1" ;;
  esac
}

snap_one_line() {
  _f=$1
  if [ -f "$_f" ]; then
    tr '\n' ' ' <"$_f" | sed 's/[[:space:]]\{1,\}/ /g'
  else
    echo "(absent)"
  fi
}

# Last EXIT_REASON / main_loop lines only (not full log spam).
log_exit_tail() {
  if [ ! -f "$LOG" ]; then
    echo "(log-absent)"
    return
  fi
  # Prefer choke-point strings; fall back to last 8 lines if none.
  _hit=$(grep -E 'EXIT_REASON|main_loop exit pending|FRAME_LEDGER event=process_' "$LOG" 2>/dev/null | tail -n 6 | tr '\n' '|' | sed 's/[[:space:]]\{1,\}/ /g')
  if [ -n "$_hit" ]; then
    echo "$_hit"
  else
    tail -n 8 "$LOG" 2>/dev/null | tr '\n' '|' | sed 's/[[:space:]]\{1,\}/ /g'
  fi
}

# kill -9 / crash cannot run daemon atexit. Resume stopped product Main so
# F12/OSD return. argv0 must be EXACTLY /media/fat/MiSTer.
resume_stopped_main() {
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    a0=$(tr '\0' '\n' <"$d/cmdline" 2>/dev/null | head -n1) || continue
    [ -n "$a0" ] || continue
    [ "$a0" = "/media/fat/MiSTer" ] || continue
    p=${d#/proc/}
    st=$(tr ')' '\n' <"$d/stat" 2>/dev/null | tail -n 1 | awk '{print $1}')
    if [ "$st" = "T" ]; then
      kill -CONT "$p" 2>/dev/null || true
      echo "$(ts) RESUME_MAIN pid=$p (was T)" >>"$SUPLOG"
    fi
  done
}

echo "$(ts) PLEXCTL_SUPERVISE_START root=$ROOT lock=$LOCK" >>"$SUPLOG"
trap 'kill $child 2>/dev/null || true; resume_stopped_main; exit 0' TERM INT

while true; do
  resume_stopped_main
  if [ ! -x "$BIN" ]; then
    echo "$(ts) MISSING $BIN" >>"$SUPLOG"
    sleep 5
    continue
  fi
  if [ ! -f "$CONF" ]; then
    echo "$(ts) MISSING $CONF" >>"$SUPLOG"
    sleep 5
    continue
  fi
  echo "$(ts) SPAWN $BIN conf=$CONF" >>"$SUPLOG"
  spawn_ts=$(date +%s)
  "$BIN" --name "$NAME" --id "$ID" --port "$PORT" --conf "$CONF" >>"$LOG" 2>&1 &
  child=$!
  wait "$child"
  st=$?
  now_ts=$(date +%s)
  ran_s=$((now_ts - spawn_ts))

  death_snap=$(snap_one_line "$DEATH")
  last_snap=$(snap_one_line "$LAST")
  log_snap=$(log_exit_tail)

  if [ "$st" -ge 128 ]; then
    sig=$((st - 128))
    sname=$(sig_name "$sig")
    how="WIFSIGNALED_approx signal=$sig signal_name=$sname"
  else
    how="WIFEXITED_approx exit_status=$st"
  fi

  # Parse si_* from death snap AT DETECTION TIME (pid may recycle later).
  si_pid=$(printf '%s' "$death_snap" | sed -n 's/.*si_pid=\([-0-9][0-9]*\).*/\1/p' | head -n1)
  si_code=$(printf '%s' "$death_snap" | sed -n 's/.*si_code=\([-0-9][0-9]*\).*/\1/p' | head -n1)
  si_code_name=$(printf '%s' "$death_snap" | sed -n 's/.*si_code_name=\([^ ]*\).*/\1/p' | head -n1)
  death_sig=$(printf '%s' "$death_snap" | sed -n 's/.*signal=\([-0-9][0-9]*\).*/\1/p' | head -n1)
  sender_cmd="(gone)"
  sender_ppid="?"
  sender_chain="?"
  if [ -n "${si_pid:-}" ] && [ "$si_pid" -gt 0 ] 2>/dev/null && [ -r "/proc/$si_pid/cmdline" ]; then
    sender_cmd=$(tr '\0' ' ' <"/proc/$si_pid/cmdline" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g')
    sender_ppid=$(awk '{print $4}' "/proc/$si_pid/stat" 2>/dev/null || echo '?')
    chain="$si_pid"
    walk=$sender_ppid
    i=0
    while [ -n "$walk" ] && [ "$walk" != "0" ] && [ "$walk" != "1" ] && [ "$i" -lt 6 ]; do
      if [ -r "/proc/$walk/cmdline" ]; then
        c=$(tr '\0' ' ' <"/proc/$walk/cmdline" 2>/dev/null | sed 's/[[:space:]]\{1,\}/ /g' | cut -c1-80)
        chain="$chain <- $walk:$c"
        walk=$(awk '{print $4}' "/proc/$walk/stat" 2>/dev/null || echo 0)
      else
        chain="$chain <- $walk:(gone)"
        break
      fi
      i=$((i + 1))
    done
    sender_chain="$chain"
  elif [ -n "${si_pid:-}" ]; then
    sender_cmd="(pid_gone si_pid=$si_pid)"
  fi

  if [ "$ran_s" -ge "$HEALTHY_SECS" ]; then
    if [ "$backoff" -ne 2 ]; then
      echo "$(ts) BACKOFF_RESET after healthy run_s=$ran_s (was ${backoff}s → 2s)" >>"$SUPLOG"
    fi
    backoff=2
  fi

  # Keep legacy "EXIT pid= rc= run_s=" prefix so existing greps still match,
  # then append attribution fields required to settle handled-SIGTERM vs self-exit.
  echo "$(ts) EXIT pid=$child rc=$st run_s=$ran_s $how death_sig=${death_sig:-?} si_code=${si_code:-?} si_code_name=${si_code_name:-?} si_pid=${si_pid:-?} sender_cmd=[$sender_cmd] sender_ppid=$sender_ppid sender_chain=[$sender_chain] death=[$death_snap] last=[$last_snap] log_tail=[$log_snap] — respawn in ${backoff}s" >>"$SUPLOG"

  resume_stopped_main
  sleep "$backoff"
  if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
    if [ "$backoff" -lt 60 ]; then
      backoff=$((backoff * 2))
    fi
  fi
done
