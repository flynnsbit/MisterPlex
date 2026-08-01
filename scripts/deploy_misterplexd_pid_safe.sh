#!/usr/bin/env bash
# Safe misterplexd deploy — PID-before-rename + SUPERVISOR-aware restart.
#
# TRAPS (parent-measured):
# 1) Rename-before-kill: /proc/PID/exe follows the RENAMED path; *misterplexd
#    globs match nothing; kill is a silent no-op; old daemon keeps running.
# 2) Supervisor race: device runs misterplexd_supervise.sh. kill-then-manual-start
#    lets the supervisor respawn the OLD binary between kill and mv, then the
#    manual start makes a SECOND daemon (both bind :3005, both drive DDR).
#
# SAFE ORDER (parent deploy that worked):
#   stage new inode → cp live to .prev (content copy) → mv staged onto live path
#   (rename of path survives execution; cp onto running binary = ETXTBSY) →
#   kill by captured PID only → let SUPERVISOR restart → verify readlink+md5.
#
# Rules:
#   - Capture PID(s) via pidof BEFORE any path replace.
#   - Never match cmdline (flock cmdline contains "misterplexd").
#   - pgrep does NOT exist on MiSTer busybox — pidof only.
#   - After restart: readlink -f /proc/<newpid>/exe and md5 THAT path.
#   - Do NOT touch user conf.
#
# Host agent does not run this against the device unless parent asks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN_LOCAL="${BIN_LOCAL:-$ROOT/build/arm/misterplexd}"
REMOTE_ROOT="${REMOTE_ROOT:-/media/fat/misterplex_v2}"
REMOTE_BIN="${REMOTE_ROOT}/bin/misterplexd"
# Supervisor (if present) owns restart. Empty SUPERVISOR_WAIT_S skips wait loop.
SUPERVISOR_WAIT_S="${SUPERVISOR_WAIT_S:-8}"
ALLOW_MANUAL_START="${ALLOW_MANUAL_START:-0}"
PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
CONF_PATH="${REMOTE_CONF:-${REMOTE_ROOT}/misterplex.conf}"

if [[ ! -f "$BIN_LOCAL" ]]; then
  echo "missing local binary: $BIN_LOCAL (run: make arm-plexd)" >&2
  exit 1
fi

LOCAL_MD5="$(md5sum "$BIN_LOCAL" | awk '{print $1}')"
echo "LOCAL_MD5=$LOCAL_MD5 path=$BIN_LOCAL"

ssh_cmd() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "$@"
}
scp_cmd() {
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$@"
}

STAGED="${REMOTE_BIN}.new.${LOCAL_MD5}"
ssh_cmd "mkdir -p '${REMOTE_ROOT}/bin'"
scp_cmd "$BIN_LOCAL" "$USER@$HOST:$STAGED"
echo "STAGED=$STAGED"

# 1) Capture PIDs BEFORE any move of the live path.
OLD_PIDS="$(ssh_cmd "pidof misterplexd 2>/dev/null || true")"
echo "OLD_PIDS=${OLD_PIDS:-none}"

# 2) Preserve previous binary by content copy (not rename-of-running).
ssh_cmd "if [ -f '$REMOTE_BIN' ]; then cp -f '$REMOTE_BIN' '${REMOTE_BIN}.prev.${LOCAL_MD5}'; fi"

# 3) mv staged onto the live path WHILE old process may still be running.
#    rename(2) replaces the directory entry; running inode keeps old bytes until exit.
#    This is the opposite of kill-then-mv (supervisor can respawn old between them).
ssh_cmd "mv -f '$STAGED' '$REMOTE_BIN' && chmod +x '$REMOTE_BIN'"
echo "LIVE_PATH_UPDATED=$REMOTE_BIN"

# 4) Kill by captured PID only (not cmdline glob). Supervisor restarts new path.
if [[ -n "${OLD_PIDS:-}" ]]; then
  for p in $OLD_PIDS; do
    ssh_cmd "kill -9 '$p' 2>/dev/null || true"
  done
fi

# 5) Wait for supervisor (or optional manual start) to bring up new md5.
ssh_cmd "set -e
expect='${LOCAL_MD5}'
bin='${REMOTE_BIN}'
ok=0
for i in \$(seq 1 ${SUPERVISOR_WAIT_S}); do
  sleep 1
  NEW_PIDS=\$(pidof misterplexd 2>/dev/null || true)
  for p in \$NEW_PIDS; do
    case \" ${OLD_PIDS} \" in
      *\" \$p \"*) continue ;;
    esac
    exe=\$(readlink -f /proc/\$p/exe 2>/dev/null || true)
    [ -n \"\$exe\" ] || continue
    m=\$(md5sum \"\$exe\" | awk '{print \$1}')
    echo WAIT_i=\$i PID=\$p EXE=\$exe LIVE_MD5=\$m
    if [ \"\$m\" = \"\$expect\" ]; then ok=1; break; fi
  done
  [ \"\$ok\" = 1 ] && break
done

if [ \"\$ok\" != 1 ] && [ '${ALLOW_MANUAL_START}' = 1 ]; then
  echo SUPERVISOR_MISS manual_start
  nohup \"\$bin\" --name MiSTerPlex --id '${PLAYER_ID}' --port 3005 \
    --conf '${CONF_PATH}' >>'${REMOTE_ROOT}/misterplexd.log' 2>&1 &
  sleep 1
fi

NEW_PIDS=\$(pidof misterplexd 2>/dev/null || true)
echo NEW_PIDS=\${NEW_PIDS:-none}
ok=0
n_match=0
for p in \$NEW_PIDS; do
  exe=\$(readlink -f /proc/\$p/exe 2>/dev/null || true)
  echo PID=\$p EXE=\$exe
  if [ -n \"\$exe\" ] && [ -f \"\$exe\" ]; then
    m=\$(md5sum \"\$exe\" | awk '{print \$1}')
    echo LIVE_MD5=\$m
    if [ \"\$m\" = \"\$expect\" ]; then ok=1; n_match=\$((n_match+1)); fi
  fi
done
if [ \"\$ok\" != 1 ]; then
  echo DEPLOY_VERIFY_FAIL expected_md5=\$expect
  exit 2
fi
if [ \"\$n_match\" -gt 1 ]; then
  echo DEPLOY_VERIFY_FAIL reason=multiple_daemons_match_md5 n=\$n_match
  exit 3
fi
echo DEPLOY_VERIFY_OK md5=\$expect n_daemon=\$(echo \$NEW_PIDS | wc -w)
n=\$(wget -qO- http://127.0.0.1:3005/resources 2>/dev/null | wc -c || echo 0)
echo resources_bytes=\$n
"

echo "Deploy complete. LOCAL_MD5=$LOCAL_MD5"
