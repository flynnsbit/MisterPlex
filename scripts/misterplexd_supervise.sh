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

echo "$(ts) PLEXCTL_SUPERVISE_START root=$ROOT lock=$LOCK" >>"$SUPLOG"
# TERM/INT must NOT exit 0 — silent disarm of daily driver (parent 2026-07-31).
_on_supervise_signal() {
  sig="$1"
  code="$2"
  echo "$(ts) SUPERVISE_SIGNAL sig=$sig killing_child=${child:-none} — exit $code (not silent disarm)" >>"$SUPLOG"
  if [ -n "${child:-}" ]; then
    kill "$child" 2>/dev/null || true
  fi
  resume_stopped_main
  exit "$code"
}
trap '_on_supervise_signal TERM 143' TERM
trap '_on_supervise_signal INT 130' INT

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
  echo "$(ts) EXIT pid=$child rc=$st run_s=$ran_s — respawn in ${backoff}s" >>"$SUPLOG"
  resume_stopped_main
  sleep "$backoff"
  if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
    if [ "$backoff" -lt 60 ]; then
      backoff=$((backoff * 2))
    fi
  fi
done
