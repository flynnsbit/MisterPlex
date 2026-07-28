#!/usr/bin/env bash
# Repeat the Plex Web cast gate N times and report a pass rate.
# The MiSTer is a shared lab device: another agent restarting misterplexd mid-run
# would invalidate that run, so each run is bracketed by a daemon identity probe
# (pid + /proc start ticks). Runs whose daemon identity changed are reported as
# CONFOUNDED and excluded from the denominator instead of being scored.
set -o pipefail
N=${N:-5}; LOG=${LOG:-build/cast_rate.log}; : > "$LOG"
HOST=${MISTER_HOST:-192.168.1.183}
export PLAYWRIGHT_MODULE=${PLAYWRIGHT_MODULE:-/home/flynnsbit/Projects/MisterPlex/.worktrees/w-e2e/tests/hw/e2e/node_modules/playwright}
export PLEX_BASE=${PLEX_BASE:-http://127.0.0.1:32400} PLEX_HOME_USER=${PLEX_HOME_USER:-shawnhenderson}
export PLEX_SERVER_ID=${PLEX_SERVER_ID:-4edd44aac1de0b731553a3a187104ecd175571a0} MISTERPLEX_ID=${MISTERPLEX_ID:-misterplex-183}
ident() { sshpass -p "${MISTER_PASS:-1}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@"$HOST" \
  'p=$(pidof misterplexd); echo "$p:$(awk "{print \$22}" /proc/$p/stat 2>/dev/null)"' 2>/dev/null | tr -d '\r'; }
pass=0; fail=0; other=0; conf=0
for i in $(seq 1 "$N"); do
  a=$(ident)
  out=$(timeout 420 node tests/hw/e2e/cast_play_web_e2e.js 2>&1); rc=$?
  b=$(ident)
  echo "=== run $i rc=$rc daemon_before=$a daemon_after=$b" >> "$LOG"; echo "$out" >> "$LOG"
  line=$(echo "$out" | grep -E 'CAST_E2E_(FAIL|SKIP|REFUSE)|CAST_E2E_OK' | head -1 | cut -c1-150)
  if [ -z "$a" ] || [ "$a" != "$b" ]; then
    conf=$((conf+1)); echo "run $i CONFOUNDED (daemon $a -> $b) rc=$rc :: $line"
  else
    case $rc in 0) pass=$((pass+1));; 1) fail=$((fail+1));; *) other=$((other+1));; esac
    echo "run $i rc=$rc :: $line"
  fi
  curl -s -o /dev/null -m 8 "http://$HOST:3005/player/playback/stop?commandID=99" || true
  sleep 5
done
echo "RATE pass=$pass fail=$fail other=$other scored_denominator=$((pass+fail+other)) confounded=$conf attempts=$N"
