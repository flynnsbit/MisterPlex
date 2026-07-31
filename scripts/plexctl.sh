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
# Running-core claim: the only host-side record of *which* RBF was loaded.
# /tmp/CORENAME and /tmp/RBFNAME content are always "Plex" — not identity.
RUNNING_CORE_CLAIM="${RUNNING_CORE_CLAIM:-/media/fat/misterplex/.running_core_claim}"

write_running_core_claim() {
  core="$1"
  mtime="$2"
  md=$(md5sum "$core" 2>/dev/null | awk '{print $1}')
  if [ -z "$md" ] || [ -z "$mtime" ]; then
    echo "$(ts) CORE_CLAIM_FAIL core=$core md5='${md}' mtime='${mtime}'"
    return 4
  fi
  mkdir -p "$(dirname "$RUNNING_CORE_CLAIM")"
  {
    echo "version=1"
    echo "md5=$md"
    echo "path=$core"
    echo "rbfname_mtime=$mtime"
    echo "source=plexctl"
  } >"$RUNNING_CORE_CLAIM"
  echo "$(ts) CORE_CLAIM_OK md5=$md path=$core rbfname_mtime=$mtime claim=$RUNNING_CORE_CLAIM"
  return 0
}

load_core() {
  core="$1"
  [ -f "$core" ] || { echo "ERROR no core at $core"; return 2; }
  before=$(stat -c %Y /tmp/RBFNAME 2>/dev/null || echo 0)
  printf 'load_core %s\n' "$core" > /dev/MiSTer_cmd
  i=0
  while [ "$i" -lt 40 ]; do
    sleep 0.5
    after=$(stat -c %Y /tmp/RBFNAME 2>/dev/null || echo 0)
    if [ "$after" != "$before" ]; then
      echo "$(ts) CORE_LOADED $core (RBFNAME mtime $before -> $after)"
      write_running_core_claim "$core" "$after" || return $?
      sleep 3
      return 0
    fi
    i=$((i + 1))
  done
  echo "CORE_LOAD_UNCONFIRMED $core (RBFNAME mtime did not advance from $before)"
  # Do NOT leave a stale claim pretending this load succeeded.
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

# Writes the supervisor that actually holds the lock for its whole lifetime.
write_supervisor() {
  root="$1"
  cat > /tmp/plexctl_supervise.sh <<EOF
#!/bin/sh
set -u
ROOT=$root
BIN=\$ROOT/bin/misterplexd
CONF=\$ROOT/misterplex.conf
LOG=\$ROOT/misterplexd.log
SUPLOG=\$ROOT/misterplexd_supervise.log
backoff=2
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# kill -9 / crash with no handler cannot run daemon atexit. Before every spawn
# and after every exit, SIGCONT any stopped product Main so F12/OSD return.
# argv0 must be EXACTLY /media/fat/MiSTer (first cmdline token) — no substring.
resume_stopped_main() {
  for d in /proc/[0-9]*; do
    [ -r "\$d/cmdline" ] || continue
    a0=\$(tr '\\0' '\\n' < "\$d/cmdline" 2>/dev/null | head -n1) || continue
    [ -n "\$a0" ] || continue
    [ "\$a0" = "/media/fat/MiSTer" ] || continue
    p=\${d#/proc/}
    st=\$(tr ')' '\\n' < "\$d/stat" 2>/dev/null | tail -n 1 | awk '{print \$1}')
    if [ "\$st" = "T" ]; then
      kill -CONT "\$p" 2>/dev/null || true
      echo "\$(ts) RESUME_MAIN pid=\$p (was T)" >>"\$SUPLOG"
    fi
  done
}
echo "\$(ts) PLEXCTL_SUPERVISE_START root=\$ROOT" >>"\$SUPLOG"
trap 'kill \$child 2>/dev/null || true; resume_stopped_main; exit 0' TERM INT
# After a sustained healthy run, forget prior crash-loop backoff. 120s is long
# enough that a 1s crash-loop still doubles backoff, short enough that a late
# intermittent SIGSEGV does not leave the daily driver dark for 64s hours later.
HEALTHY_SECS=120
while true; do
  resume_stopped_main
  [ -x "\$BIN" ] || { echo "\$(ts) MISSING \$BIN" >>"\$SUPLOG"; sleep 5; continue; }
  echo "\$(ts) SPAWN \$BIN" >>"\$SUPLOG"
  spawn_ts=\$(date +%s)
  "\$BIN" --name $NAME --id $ID --port $PORT --conf "\$CONF" >>"\$LOG" 2>&1 &
  child=\$!
  wait "\$child"; st=\$?
  now_ts=\$(date +%s)
  ran_s=\$((now_ts - spawn_ts))
  if [ "\$ran_s" -ge "\$HEALTHY_SECS" ]; then
    if [ "\$backoff" -ne 2 ]; then
      echo "\$(ts) BACKOFF_RESET after healthy run_s=\$ran_s (was \${backoff}s → 2s)" >>"\$SUPLOG"
    fi
    backoff=2
  fi
  echo "\$(ts) EXIT pid=\$child rc=\$st run_s=\$ran_s — respawn in \${backoff}s" >>"\$SUPLOG"
  resume_stopped_main
  sleep "\$backoff"
  # Grow backoff only after short (unhealthy) runs — not after a reset-worthy life.
  if [ "\$ran_s" -lt "\$HEALTHY_SECS" ]; then
    [ "\$backoff" -lt 60 ] && backoff=\$((backoff * 2))
  fi
done
EOF
  chmod +x /tmp/plexctl_supervise.sh
}

start_bundle() {
  root="$1"
  [ -x "$root/bin/misterplexd" ] || { echo "ERROR no daemon at $root/bin/misterplexd"; exit 2; }
  [ -f "$root/misterplex.conf" ] || { echo "ERROR no conf at $root/misterplex.conf"; exit 2; }

  stop_all || exit 9
  write_supervisor "$root"

  # flock -n: if another supervisor already holds it, fail rather than duplicate.
  # The lock is held for the supervisor's entire lifetime via fd 9.
  nohup flock -n "$LOCK" /tmp/plexctl_supervise.sh >/dev/null 2>&1 &
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
