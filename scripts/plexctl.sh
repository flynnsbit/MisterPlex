#!/bin/sh
# plexctl.sh — single-instance launcher/switcher for misterplexd on the MiSTer.
#
# Why this exists: two supervisors and two daemons were observed running at once
# (both bound to UDP 32412 via SO_REUSEPORT, only one owning TCP 3005). Two
# daemons write frames to the same canvas, which corrupts the picture in a way
# that follows the daemon across different cores. dedupe_daemon.sh raced:
# it spawned the supervisor, slept 2s, then spawned a second daemon if the
# supervisor's child had not appeared yet.
#
# Contract: exactly one supervisor may hold the lock, and only the supervisor
# spawns the daemon. A second invocation fails fast instead of duplicating.
#
# Usage: plexctl.sh {dev|v2|stop|status}
#   dev    run the development bundle  (/media/fat/misterplex)
#   v2     run the v0.2.0 known-good bundle (/media/fat/misterplex_v2)
#   stop   stop everything
#   status report what is running

set -eu

LOCK=/tmp/misterplexd.lock
DEV_ROOT=/media/fat/misterplex
V2_ROOT=/media/fat/misterplex_v2
NAME=MiSTerPlex
ID=misterplex-dev
PORT=3005

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

DEV_CORE=/media/fat/Plex.rbf
V2_CORE=/media/fat/_Utility/Plex_v2.rbf
V3_CORE=/media/fat/_Utility/Plex_v3.rbf

# Load an RBF and prove the load actually happened.
#
# There is NO way to read back which bitstream is live: /tmp/CORENAME and
# /tmp/RBFNAME both come from the bitstream CONF_STR, and every Plex build
# reports "Plex", so Plex.rbf, Plex_v2.rbf and Plex_v3.rbf are indistinguishable
# by name. Measured on hardware: after loading Plex_v2.rbf, RBFNAME was [Plex].
#
# What IS observable is that /tmp/RBFNAME's mtime advances on every load, so use
# that as the "the core really reloaded" signal. Confirming *which* core is live
# requires an HDMI capture fingerprint (tools/measure_edges.py) and is the
# caller's job, not this function's.
# This script only makes sense running ON the MiSTer: every path it tests is a
# DEVICE path. Run from a host workstation, `[ -f "$core" ]` evaluates the device
# path against the HOST filesystem and reports the daily driver's core as missing
# when it is present and healthy. A rollback tool that falsely claims the core is
# destroyed is dangerous, so refuse up front instead of guessing.
require_on_device() {
  [ -w /dev/MiSTer_cmd ] || {
    echo "ERROR not on MiSTer (no writable /dev/MiSTer_cmd) — device paths cannot be" \
         "checked on-device from a host; run this script on the MiSTer" >&2
    return 3
  }
}

load_core() {
  core="$1"
  require_on_device || return 3
  [ -f "$core" ] || { echo "ERROR no core at $core"; return 2; }
  before=$(stat -c %Y /tmp/RBFNAME 2>/dev/null || echo 0)
  printf 'load_core %s\n' "$core" > /dev/MiSTer_cmd
  i=0
  while [ "$i" -lt 40 ]; do
    sleep 0.5
    after=$(stat -c %Y /tmp/RBFNAME 2>/dev/null || echo 0)
    if [ "$after" != "$before" ]; then
      echo "$(ts) CORE_LOADED $core (RBFNAME mtime $before -> $after)"
      sleep 3
      return 0
    fi
    i=$((i + 1))
  done
  echo "CORE_LOAD_UNCONFIRMED $core (RBFNAME mtime did not advance from $before)"
  return 4
}

# Supervisor patterns, most-supervisory first, so nothing respawns the daemon
# underneath us. dedupe_daemon.sh is the legacy racy launcher and must never be
# left running alongside this one.
SUPERVISORS='plexctl_supervise.sh misterplexd_supervise.sh dedupe_daemon.sh'
DAEMON='/bin/misterplexd'

# Match by /proc cmdline, NOT pidof. pidof only matches the executable, so a
# script started as "/bin/sh /tmp/plexctl_supervise.sh" is invisible to it.
# Observed on hardware: a stale supervisor survived `pidof plexctl_supervise.sh`
# and silently respawned a second daemon after a stop.
pids_matching() {
  pat="$1"
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p=${d#/proc/}
    if [ "$p" = "$$" ]; then continue; fi
    [ -r "$d/cmdline" ] || continue
    cmd=$( (tr '\0' ' ' < "$d/cmdline") 2>/dev/null ) || continue
    # Never match this controller or its own forked subshells, which inherit
    # the parent cmdline and would otherwise look like a target process.
    case "$cmd" in
      *plexctl.sh*) continue ;;
    esac
    case "$cmd" in
      *"$pat"*) echo "$p" ;;
    esac
  done
}

any_running() {
  for pat in $SUPERVISORS $DAEMON; do
    if [ -n "$(pids_matching "$pat")" ]; then return 0; fi
  done
  return 1
}

stop_all() {
  for pat in $SUPERVISORS $DAEMON; do
    for p in $(pids_matching "$pat"); do
      kill "$p" 2>/dev/null || true
    done
  done
  i=0
  while any_running; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
      echo "STOP_FAILED still running; refusing kill -9"
      for pat in $SUPERVISORS $DAEMON; do
        for p in $(pids_matching "$pat"); do
          printf 'STILL_UP pid=%s ' "$p"
          tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null
          echo
        done
      done
      return 9
    fi
    sleep 0.25
  done
  return 0
}

status() {
  echo "n_daemon=$(pids_matching "$DAEMON" | wc -w)"
  n_sup=0
  for pat in $SUPERVISORS; do
    n_sup=$((n_sup + $(pids_matching "$pat" | wc -w)))
  done
  echo "n_supervise=$n_sup"
  ps | grep -E "[m]isterplexd|[p]lexctl_supervise|[d]edupe_daemon" | head -10 || true
  netstat -lnp 2>/dev/null | grep -E ":$PORT|:32412" || true
  for p in $(pids_matching "$DAEMON"); do
    printf 'cmdline: '
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null
    echo
  done
}

# Supervisor SoT is scripts/misterplexd_supervise.sh, installed by
# deploy_misterplexd.sh to $root/bin/misterplexd_supervise.sh. plexctl must NOT
# embed a second divergent copy (device drift class: md5 59286a1d in no commit).
require_durable_supervisor() {
  root="$1"
  sup="$root/bin/misterplexd_supervise.sh"
  [ -x "$sup" ] || {
    echo "ERROR missing durable supervisor at $sup" >&2
    echo "     install via scripts/deploy_misterplexd.sh (ships repo SoT + verifies md5)" >&2
    return 2
  }
  printf '%s' "$sup"
}

start_bundle() {
  root="$1"
  [ -x "$root/bin/misterplexd" ] || { echo "ERROR no daemon at $root/bin/misterplexd"; exit 2; }
  [ -f "$root/misterplex.conf" ] || { echo "ERROR no conf at $root/misterplex.conf"; exit 2; }
  sup=$(require_durable_supervisor "$root") || exit 2

  stop_all || exit 9

  # Durable supervisor self-flocks /tmp/misterplexd_supervise.lock (fd 9).
  # Do not wrap a second flock on $LOCK (/tmp/misterplexd.lock) — that path is
  # historical and does not coordinate with cold-boot. Never rewrite /tmp.
  nohup "$sup" >/dev/null 2>&1 &
  sleep 3

  n=$(pids_matching "$DAEMON" | wc -w)
  echo "$(ts) started root=$root n_daemon=$n"
  [ "$n" -eq 1 ] || { echo "ERROR expected exactly 1 daemon, got $n"; status; exit 3; }
  status
}

# Full graceful cycle: stop the daemon FIRST (so nothing writes frames while the
# fabric is reconfiguring, and so the binary is not busy), reload the core, prove
# it loaded, then bring the daemon back up.
reload_bundle() {
  root="$1"
  core="$2"
  stop_all || exit 9
  load_core "$core" || exit 4
  start_bundle "$root"
}

case "${1:-status}" in
  dev)        start_bundle "$DEV_ROOT" ;;
  v2)         start_bundle "$V2_ROOT" ;;
  reload-dev) reload_bundle "$DEV_ROOT" "$DEV_CORE" ;;
  reload-v2)  reload_bundle "$V2_ROOT" "$V2_CORE" ;;
  stop)       stop_all && echo "stopped" && status ;;
  status)     status ;;
  *)          echo "usage: $0 {dev|v2|reload-dev|reload-v2|stop|status}"; exit 1 ;;
esac
