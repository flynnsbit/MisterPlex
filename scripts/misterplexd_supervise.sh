#!/bin/sh
# misterplexd_supervise.sh — durable single-instance supervisor for misterplexd.
#
# Install to: $ROOT/bin/misterplexd_supervise.sh  (ROOT = live pair root,
# normally /media/fat/misterplex_v2). Boot hook must invoke THIS path, never
# the v1 root and never a bare misterplexd (parent 2026-07-31 cold-boot defect).
#
# Contract (parent-measured on device):
#   - ROOT derived from this script's location (…/bin/misterplexd_supervise.sh)
#   - BIN=$ROOT/bin/misterplexd  CONF=$ROOT/misterplex.conf
#   - single-instance: flock -n /tmp/misterplexd_supervise.lock (fd 9)
#   - HEALTHY_SECS=120 backoff reset after sustained healthy run
#   - resume_stopped_main: argv0 must be EXACTLY /media/fat/MiSTer (no substring)
#   - never identify misterplexd by cmdline substring (flock trap)
#   - SUPERVISE_EXIT snapshots misterplexd.death (sig/si_pid/si_code) + sender
#     cmdline at detection time — required for rc=0 soak-exit RCA
#
# This supervisor does NOT kill the child on a timer or health probe. It only
# wait(2)s and respawns. A clean child rc=0 is handled SIGTERM/INT inside the
# daemon (main_loop_g_stop), not a voluntary idle exit. Sender is external
# unless this script's TERM/INT trap fires (forwards signal to the child).
#
# Do not edit on-device only — keep this file the repo source of truth.

set -u

# Resolve ROOT from script path when possible; allow override for tests.
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
NAME=${MISTERPLEX_NAME:-MiSTerPlex}
ID=${MISTERPLEX_ID:-misterplex-dev}
PORT=${MISTERPLEX_PORT:-3005}
LOCK=${MISTERPLEX_SUPERVISE_LOCK:-/tmp/misterplexd_supervise.lock}
HEALTHY_SECS=${MISTERPLEX_HEALTHY_SECS:-120}

# Single-instance guard — boot hook may be re-entered; never two supervisors.
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SUPERVISE_ALREADY_HELD lock=$LOCK root=$ROOT" >>"$SUPLOG" 2>/dev/null || true
  exit 0
fi

backoff=2
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

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

# Snapshot death breadcrumb + sender at the moment wait returns (not later).
# Defect class: clean rc=0 mid-soak with no attribution (si_pid recycled).
log_supervise_exit() {
  child=$1
  st=$2
  ran_s=$3
  if [ "$st" -ge 128 ]; then
    sig=$((st - 128))
    how="WIFSIGNALED_approx signal=$sig"
  else
    how="WIFEXITED_approx exit_status=$st"
  fi
  death_snap="(absent)"
  [ -f "$ROOT/misterplexd.death" ] && death_snap=$(tr '\n' ' ' <"$ROOT/misterplexd.death" | sed 's/[[:space:]]\+/ /g')
  last_snap="(absent)"
  [ -f "$ROOT/misterplexd.last" ] && last_snap=$(tr '\n' ' ' <"$ROOT/misterplexd.last" | sed 's/[[:space:]]\+/ /g')
  sender_cmd="(gone)"
  sender_ppid="?"
  sender_chain="?"
  si_pid=$(printf '%s' "$death_snap" | sed -n 's/.*si_pid=\([-0-9][0-9]*\).*/\1/p' | head -n1)
  si_code=$(printf '%s' "$death_snap" | sed -n 's/.*si_code=\([-0-9][0-9]*\).*/\1/p' | head -n1)
  si_code_name=$(printf '%s' "$death_snap" | sed -n 's/.*si_code_name=\([^ ]*\).*/\1/p' | head -n1)
  if [ -n "$si_pid" ] && [ "$si_pid" -gt 0 ] 2>/dev/null && [ -r "/proc/$si_pid/cmdline" ]; then
    sender_cmd=$(tr '\0' ' ' <"/proc/$si_pid/cmdline" 2>/dev/null | sed 's/[[:space:]]\+/ /g')
    sender_ppid=$(awk '{print $4}' "/proc/$si_pid/stat" 2>/dev/null || echo '?')
    chain="$si_pid"
    walk=$sender_ppid
    i=0
    while [ -n "$walk" ] && [ "$walk" != "0" ] && [ "$walk" != "1" ] && [ "$i" -lt 6 ]; do
      if [ -r "/proc/$walk/cmdline" ]; then
        c=$(tr '\0' ' ' <"/proc/$walk/cmdline" 2>/dev/null | sed 's/[[:space:]]\+/ /g' | cut -c1-80)
        chain="$chain <- $walk:$c"
        walk=$(awk '{print $4}' "/proc/$walk/stat" 2>/dev/null || echo 0)
      else
        chain="$chain <- $walk:(gone)"
        break
      fi
      i=$((i + 1))
    done
    sender_chain="$chain"
  elif [ -n "$si_pid" ]; then
    sender_cmd="(pid_gone si_pid=$si_pid)"
  fi
  echo "$(ts) SUPERVISE_EXIT pid=$child wait_st=$st $how run_s=$ran_s death=[$death_snap] last=[$last_snap] si_code=${si_code:-?} si_code_name=${si_code_name:-?} si_pid=${si_pid:-?} sender_cmd=[$sender_cmd] sender_ppid=$sender_ppid sender_chain=[$sender_chain] — respawn in ${backoff}s" >>"$SUPLOG"
}

echo "$(ts) PLEXCTL_SUPERVISE_START root=$ROOT lock=$LOCK" >>"$SUPLOG"
# Only place THIS script sends a signal to the child: external TERM/INT to us.
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
  if [ "$ran_s" -ge "$HEALTHY_SECS" ]; then
    if [ "$backoff" -ne 2 ]; then
      echo "$(ts) BACKOFF_RESET after healthy run_s=$ran_s (was ${backoff}s → 2s)" >>"$SUPLOG"
    fi
    backoff=2
  fi
  log_supervise_exit "$child" "$st" "$ran_s"
  resume_stopped_main
  sleep "$backoff"
  if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
    if [ "$backoff" -lt 60 ]; then
      backoff=$((backoff * 2))
    fi
  fi
done
