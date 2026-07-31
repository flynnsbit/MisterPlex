#!/usr/bin/env bash
# quarantine_stale_daemon_tree.sh — make a wrong boot hook FAIL LOUDLY.
#
# Parent 2026-07-31: known-bad v1 daemon 54f1d916 (pre-PLXD, pre-480p chroma)
# remains on device. A mis-pointed hook boots it silently and "successfully".
# Fail-loud beats fail-quiet on a daily driver.
#
# HOST-SIDE plan / dry-run by default. Parent executes on device.
#
# Usage:
#   scripts/quarantine_stale_daemon_tree.sh plan
#   scripts/quarantine_stale_daemon_tree.sh render-remote
#   QUARANTINE_EXECUTE=1 scripts/quarantine_stale_daemon_tree.sh apply
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
STALE_PREFIXES="${STALE_DAEMON_PREFIXES:-54f1d916}"
V1_BIN="${QUARANTINE_V1_BIN:-/media/fat/misterplex/bin/misterplexd}"
EXECUTE="${QUARANTINE_EXECUTE:-0}"

cmd="${1:-plan}"

remote_script() {
  cat <<'EOS'
set -e
bin="${QUARANTINE_V1_BIN:-/media/fat/misterplex/bin/misterplexd}"
prefixes="${STALE_DAEMON_PREFIXES:-54f1d916}"
if [ ! -f "$bin" ]; then
  echo "QUARANTINE_SKIP missing $bin"
  echo "true rc=0"
  exit 0
fi
md=$(md5sum "$bin" | awk '{print $1}')
pref=${md:0:8}
echo "QUARANTINE_PROBE path=$bin md5=$md prefix=$pref"
hit=0
for p in $prefixes; do
  case "$pref" in
    "$p"*) hit=1 ;;
  esac
done
if [ "$hit" -ne 1 ]; then
  echo "QUARANTINE_SKIP prefix $pref not in stale list ($prefixes) — not renaming"
  echo "true rc=0"
  exit 0
fi
ts=$(date -u +%Y%m%dT%H%M%SZ)
dest="${bin}.QUARANTINE.${pref}.${ts}"
mv -f "$bin" "$dest"
sync
echo "QUARANTINE_OK from=$bin to=$dest"
echo "QUARANTINE_NOTE wrong hook will now fail loud (ENOENT) instead of booting stale daemon"
if [ -f /media/fat/misterplex_v2/bin/misterplexd ]; then
  echo "V2_INTACT md5=$(md5sum /media/fat/misterplex_v2/bin/misterplexd | awk '{print $1}')"
fi
echo "true rc=0"
EOS
}

case "$cmd" in
  plan)
    cat <<EOF
=== QUARANTINE STALE DAEMON TREE (fail-loud) ===
target_bin=$V1_BIN
stale_prefixes=$STALE_PREFIXES
never_touch=/media/fat/misterplex_v2
action=rename-only (misterplexd -> misterplexd.QUARANTINE.<prefix>.<utc>)
effect=wrong boot hook -> exec fails loudly instead of silent 54f1d916 regression

Parent run:
  QUARANTINE_EXECUTE=1 $0 apply
  # or:
  $0 render-remote | sshpass -p "\$MISTER_PASS" ssh root@$HOST bash -s
EOF
    echo "true rc=0"
    ;;
  render-remote)
    remote_script
    ;;
  apply)
    if [ "$EXECUTE" != "1" ]; then
      echo "REFUSE set QUARANTINE_EXECUTE=1 (parent-only device action)"
      echo "true rc=10"
      exit 10
    fi
    set +e
    out=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "$USER@$HOST" \
      env "STALE_DAEMON_PREFIXES=$STALE_PREFIXES" "QUARANTINE_V1_BIN=$V1_BIN" \
      bash -s <<EOS
$(remote_script)
EOS
)
    rc=$?
    set -e
    printf '%s\n' "$out"
    echo "true rc=$rc"
    exit "$rc"
    ;;
  *)
    echo "usage: $0 {plan|render-remote|apply}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
