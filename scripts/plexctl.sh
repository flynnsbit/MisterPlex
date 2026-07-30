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

stop_all() {
  # Supervisors first, so nothing respawns the daemon underneath us.
  for n in plexctl_supervise.sh misterplexd_supervise.sh misterplexd; do
    for p in $(pidof "$n" 2>/dev/null || true); do
      kill "$p" 2>/dev/null || true
    done
  done
  i=0
  while pidof misterplexd >/dev/null 2>&1 \
     || pidof misterplexd_supervise.sh >/dev/null 2>&1 \
     || pidof plexctl_supervise.sh >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
      echo "STOP_FAILED still running; refusing kill -9"
      pidof misterplexd || true
      return 9
    fi
    sleep 0.25
  done
  return 0
}

status() {
  echo "n_daemon=$(pidof misterplexd 2>/dev/null | wc -w)"
  echo "n_supervise=$(( $(pidof misterplexd_supervise.sh 2>/dev/null | wc -w) \
                      + $(pidof plexctl_supervise.sh 2>/dev/null | wc -w) ))"
  ps | grep -E "[m]isterplexd|[p]lexctl_supervise" | head -10 || true
  netstat -lnp 2>/dev/null | grep -E ":$PORT|:32412" || true
  for p in $(pidof misterplexd 2>/dev/null || true); do
    printf 'cmdline: '
    tr '\0' ' ' < "/proc/$p/cmdline"
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
echo "\$(ts) PLEXCTL_SUPERVISE_START root=\$ROOT" >>"\$SUPLOG"
trap 'kill \$child 2>/dev/null || true; exit 0' TERM INT
while true; do
  [ -x "\$BIN" ] || { echo "\$(ts) MISSING \$BIN" >>"\$SUPLOG"; sleep 5; continue; }
  echo "\$(ts) SPAWN \$BIN" >>"\$SUPLOG"
  "\$BIN" --name $NAME --id $ID --port $PORT --conf "\$CONF" >>"\$LOG" 2>&1 &
  child=\$!
  wait "\$child"; st=\$?
  echo "\$(ts) EXIT pid=\$child rc=\$st — respawn in \${backoff}s" >>"\$SUPLOG"
  sleep "\$backoff"
  [ "\$backoff" -lt 60 ] && backoff=\$((backoff * 2))
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

  n=$(pidof misterplexd 2>/dev/null | wc -w)
  echo "$(ts) started root=$root n_daemon=$n"
  [ "$n" -eq 1 ] || { echo "ERROR expected exactly 1 daemon, got $n"; status; exit 3; }
  status
}

case "${1:-status}" in
  dev)    start_bundle "$DEV_ROOT" ;;
  v2)     start_bundle "$V2_ROOT" ;;
  stop)   stop_all && echo "stopped" && status ;;
  status) status ;;
  *)      echo "usage: $0 {dev|v2|stop|status}"; exit 1 ;;
esac
