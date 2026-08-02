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
  echo "$(ts) EXIT pid=$child rc=$st run_s=$ran_s — respawn in ${backoff}s" >>"$SUPLOG"
  # rc=0 after a real run: process returned cleanly. main.cpp only reaches
  # return 0 from the companion loop after g_stop (SIGINT/SIGTERM) or the lab
  # play-file path. Parent saw EXIT rc=0 run_s=1543/196/514 with no daemon
  # "shutdown|SIGTERM" lines — on_signal was silent until exit-reason logging.
  # Clean exit REZEROES droppedFrames_/presentCount_ on next stream (media_player
  # start path) → soak continuity must assert one session_epoch (P4/S1).
  if [ "$st" -eq 0 ] && [ "$ran_s" -ge 5 ]; then
    echo "$(ts) ALARM CLEAN_EXIT rc=0 run_s=$ran_s pid=$child — not a crash; SIGINT/SIGTERM or lab play-file" >>"$SUPLOG"
    echo "$(ts) REMEDY grep daemon log for 'exit reason=signal'; dmesg; who sent kill (deploy kill-by-PID?); do not quote multi-respawn soak as one session" >>"$SUPLOG"
    echo "$(ts) REMEDY host: REQUIRE_SINGLE_SESSION_EPOCH=1 scripts/promotion_session_verify.sh --from-log \$LOG" >>"$SUPLOG"
  fi
  # rc=126 = shell "found but not executable" / corrupt or incomplete ELF
  # (parent 2026-08-01: truncated scp onto live path → n_daemon=0 for ~2 min).
  if [ "$st" -eq 126 ] || [ "$st" -eq 127 ]; then
    sz=$(wc -c <"$BIN" 2>/dev/null || echo 0)
    m=$(md5sum "$BIN" 2>/dev/null | awk '{print $1}')
    echo "$(ts) ALARM CORRUPT_OR_INCOMPLETE_BINARY rc=$st run_s=$ran_s bytes=$sz md5=${m:-unknown} path=$BIN" >>"$SUPLOG"
    echo "$(ts) REMEDY never scp onto live misterplexd; use scripts/deploy_misterplexd.sh (stage+md5+mv)" >>"$SUPLOG"
    echo "$(ts) REMEDY atomic restore: cp bak to ${BIN}.restore.\$\$ && mv -f ${BIN}.restore.\$\$ $BIN then kill PID (not name)" >>"$SUPLOG"
    echo "$(ts) REMEDY host: PAIR_ID=ddr-8fdf440f-9ce2c2d1 ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.9ce2c2d1 scripts/restore_misterplexd_prev.sh" >>"$SUPLOG"
    # Cap backoff climb for corpse-respawn so recovery is not delayed 64s.
    if [ "$backoff" -gt 8 ]; then
      backoff=8
    fi
  fi
  resume_stopped_main
  sleep "$backoff"
  if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
    if [ "$backoff" -lt 60 ]; then
      # Do not explode backoff on hard corrupt binary — stay recoverable.
      if [ "$st" -eq 126 ] || [ "$st" -eq 127 ]; then
        :
      else
        backoff=$((backoff * 2))
      fi
    fi
  fi
done
