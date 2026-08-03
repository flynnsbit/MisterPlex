#!/bin/sh
set -u
ROOT=/media/fat/misterplex_v2
BIN=$ROOT/bin/misterplexd
CONF=$ROOT/misterplex.conf
LOG=$ROOT/misterplexd.log
SUPLOG=$ROOT/misterplexd_supervise.log

# Single-instance guard: the boot hook must never be able to start a second
# supervisor alongside one already running (two daemons both bind :3005 and
# both drive the DDR banks).
LOCK=/tmp/misterplexd_supervise.lock
exec 9>"$LOCK" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
fi
backoff=2
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# kill -9 / crash with no handler cannot run daemon atexit. Before every spawn
# and after every exit, SIGCONT any stopped product Main so F12/OSD return.
# argv0 must be EXACTLY /media/fat/MiSTer (first cmdline token) — no substring.
resume_stopped_main() {
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    a0=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n1) || continue
    [ -n "$a0" ] || continue
    [ "$a0" = "/media/fat/MiSTer" ] || continue
    p=${d#/proc/}
    st=$(tr ')' '\n' < "$d/stat" 2>/dev/null | tail -n 1 | awk '{print $1}')
    if [ "$st" = "T" ]; then
      kill -CONT "$p" 2>/dev/null || true
      echo "$(ts) RESUME_MAIN pid=$p (was T)" >>"$SUPLOG"
    fi
  done
}
echo "$(ts) PLEXCTL_SUPERVISE_START root=$ROOT" >>"$SUPLOG"
trap 'kill $child 2>/dev/null || true; resume_stopped_main; exit 0' TERM INT
# After a sustained healthy run, forget prior crash-loop backoff. 120s is long
# enough that a 1s crash-loop still doubles backoff, short enough that a late
# intermittent SIGSEGV does not leave the daily driver dark for 64s hours later.
HEALTHY_SECS=120
while true; do
  resume_stopped_main
  [ -x "$BIN" ] || { echo "$(ts) MISSING $BIN" >>"$SUPLOG"; sleep 5; continue; }
  echo "$(ts) SPAWN $BIN" >>"$SUPLOG"
  spawn_ts=$(date +%s)
  "$BIN" --name MiSTerPlex --id misterplex-dev --port 3005 --conf "$CONF" >>"$LOG" 2>&1 &
  child=$!
  wait "$child"; st=$?
  now_ts=$(date +%s)
  ran_s=$((now_ts - spawn_ts))
  if [ "$ran_s" -ge "$HEALTHY_SECS" ]; then
    if [ "$backoff" -ne 2 ]; then
      echo "$(ts) BACKOFF_RESET after healthy run_s=$ran_s (was ${backoff}s → 2s)" >>"$SUPLOG"
    fi
    backoff=2
  fi
  echo "$(ts) EXIT pid=$child rc=$st run_s=$ran_s — respawn in ${backoff}s" >>"$SUPLOG"
  resume_stopped_main
  sleep "$backoff"
  # Grow backoff only after short (unhealthy) runs — not after a reset-worthy life.
  if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
    [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
  fi
done
