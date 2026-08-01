#!/usr/bin/env bash
# Safe misterplexd deploy — designed around the rename-before-kill trap.
#
# TRAP (parent, measured): renaming the running binary before kill makes
# /proc/PID/exe resolve to the RENAMED path; a *misterplexd glob then matches
# NOTHING, kill is a silent no-op, and the old daemon keeps running on the
# renamed inode while every on-disk path looks correct.
#
# Rules:
#   1. Capture PID(s) via pidof BEFORE any rename/rm/mv of the binary.
#   2. Never match cmdline (flock's cmdline contains "misterplexd").
#   3. pgrep does NOT exist on MiSTer busybox — use pidof only.
#   4. After restart: readlink -f /proc/<newpid>/exe and md5 THAT path.
#
# Does NOT touch user conf. Default install root is misterplex_v2 (parent lab).
# Host agent does not run this against the device unless parent asks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN_LOCAL="${BIN_LOCAL:-$ROOT/build/arm/misterplexd}"
REMOTE_ROOT="${REMOTE_ROOT:-/media/fat/misterplex_v2}"
REMOTE_BIN="${REMOTE_ROOT}/bin/misterplexd"
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

# Stage to a NEW inode name — never rename the live binary first.
STAGED="${REMOTE_BIN}.new.${LOCAL_MD5}"
ssh_cmd "mkdir -p '${REMOTE_ROOT}/bin'"
scp_cmd "$BIN_LOCAL" "$USER@$HOST:$STAGED"

# Capture PIDs BEFORE any move of the live path.
# shellcheck disable=SC2029
OLD_PIDS="$(ssh_cmd "pidof misterplexd 2>/dev/null || true")"
echo "OLD_PIDS=${OLD_PIDS:-none}"

# Preserve previous binary by content copy (not rename-of-running).
# shellcheck disable=SC2029
ssh_cmd "if [ -f '$REMOTE_BIN' ]; then cp -f '$REMOTE_BIN' '${REMOTE_BIN}.prev.${LOCAL_MD5}'; fi"

# Kill by captured PID only (not cmdline glob).
if [[ -n "${OLD_PIDS:-}" ]]; then
  for p in $OLD_PIDS; do
    ssh_cmd "kill -9 '$p' 2>/dev/null || true"
  done
  sleep 0.5
fi

# Atomic replace of the path after process is gone.
# shellcheck disable=SC2029
ssh_cmd "mv -f '$STAGED' '$REMOTE_BIN' && chmod +x '$REMOTE_BIN'"

# Start new daemon (do not rewrite conf).
# shellcheck disable=SC2029
ssh_cmd "nohup '$REMOTE_BIN' --name MiSTerPlex --id '${PLAYER_ID}' --port 3005 --conf '${CONF_PATH}' >>'${REMOTE_ROOT}/misterplexd.log' 2>&1 & sleep 0.8; pidof misterplexd || true"

# Verify: readlink + md5 of the LIVE exe path for the new PID.
# shellcheck disable=SC2029
ssh_cmd "set -e
NEW_PIDS=\$(pidof misterplexd 2>/dev/null || true)
echo NEW_PIDS=\${NEW_PIDS:-none}
ok=0
for p in \$NEW_PIDS; do
  exe=\$(readlink -f /proc/\$p/exe 2>/dev/null || true)
  echo PID=\$p EXE=\$exe
  if [ -n \"\$exe\" ] && [ -f \"\$exe\" ]; then
    m=\$(md5sum \"\$exe\" | awk '{print \$1}')
    echo LIVE_MD5=\$m
    if [ \"\$m\" = '${LOCAL_MD5}' ]; then ok=1; fi
  fi
done
if [ \"\$ok\" != 1 ]; then
  echo DEPLOY_VERIFY_FAIL expected_md5=${LOCAL_MD5}
  exit 2
fi
echo DEPLOY_VERIFY_OK md5=${LOCAL_MD5}
n=\$(wget -qO- http://127.0.0.1:3005/resources 2>/dev/null | wc -c || echo 0)
echo resources_bytes=\$n
"

echo "Deploy complete. LOCAL_MD5=$LOCAL_MD5"
