#!/usr/bin/env bash
# fetch_daemon_pins.sh — PARENT-ONLY: pull matched-pair daemon ELFs from the MiSTer.
#
# Pins are gitignored (large ARM binaries). Rollback/promote require them on the
# host under artifacts/daemon-pins/. This script is the documented fetch step.
#
# Usage (parent; agents must not SSH):
#   scripts/fetch_daemon_pins.sh              # both SPI + DDR pins
#   scripts/fetch_daemon_pins.sh spi          # 50f4eb92 only
#   scripts/fetch_daemon_pins.sh ddr          # e9f79de2 only
#
# Env: MISTER_HOST (default 192.168.1.183), MISTER_PASS (default 1)
#
# Exit: prints true rc=N on last line. 0=all requested pins verified on host.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/artifacts/daemon-pins"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
WANT="${1:-both}"

mkdir -p "$OUT"

ssh_m() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$USER@$HOST" "$@"
}
scp_from() {
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$USER@$HOST:$1" "$2"
}

# Device candidates per pin (content-addressed backups first).
# shellcheck disable=SC2034
SPI_MD5=50f4eb925de10e29172999a565c87684
DDR_MD5=e9f79de217982aff44207664fdb945c5

fetch_one() {
  local label="$1" want_md5="$2" out_name="$3"
  local out="$OUT/$out_name" found="" remote_list rc host_md5

  echo "fetch: want $label md5=$want_md5 -> $out"

  if [ -f "$out" ]; then
    host_md5=$(md5sum "$out" | awk '{print $1}')
    if [ "$host_md5" = "$want_md5" ]; then
      echo "OK host-cache $out md5=$host_md5"
      echo "fetch_$label true rc=0"
      return 0
    fi
    echo "NOTE host file md5=$host_md5 stale — re-fetch"
  fi

  set +e
  remote_list=$(ssh_m "bash -s" <<EOS
set +e
want=$want_md5
for p in \\
  /media/fat/misterplex_v2/bin/misterplexd.\\${want:0:8}.bak \\
  /media/fat/misterplex_v2/bin/misterplexd.bak.pre-plxd \\
  /media/fat/misterplex_v2/bin/misterplexd.prev-deploy \\
  /media/fat/misterplex_v2/bin/misterplexd \\
  /media/fat/misterplex/bin/misterplexd.\\${want:0:8}.bak \\
  /media/fat/misterplex/bin/misterplexd.prev-deploy \\
  /media/fat/misterplex/bin/misterplexd \\
  /media/fat/_Utility/misterplexd.\\${want:0:8} \\
  /media/fat/_Utility/misterplexd.$label
do
  [ -f "\$p" ] || continue
  m=\$(md5sum "\$p" 2>/dev/null | awk '{print \$1}')
  [ "\$m" = "\$want" ] || continue
  echo "\$p"
  break
done
EOS
)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL ssh true rc=$rc"
    echo "fetch_$label true rc=5"
    return 5
  fi
  found=$(printf '%s\n' "$remote_list" | head -1 | tr -d '\r')
  if [ -z "$found" ]; then
    echo "FAIL no on-device file with md5=$want_md5"
    echo "fetch_$label true rc=2"
    return 2
  fi
  echo "fetch: remote $found"
  set +e
  scp_from "$found" "$out"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL scp true rc=$rc"
    echo "fetch_$label true rc=5"
    return 5
  fi
  chmod +x "$out" || true
  host_md5=$(md5sum "$out" | awk '{print $1}')
  if [ "$host_md5" != "$want_md5" ]; then
    echo "FAIL host md5 $host_md5 != want $want_md5"
    echo "fetch_$label true rc=3"
    return 3
  fi
  echo "OK fetched $out md5=$host_md5"
  file "$out" || true
  echo "fetch_$label true rc=0"
  return 0
}

rc=0
case "$WANT" in
  spi|50f4eb92)
    fetch_one spi "$SPI_MD5" misterplexd.50f4eb92 || rc=$?
    ;;
  ddr|e9f79de2)
    fetch_one ddr "$DDR_MD5" misterplexd.e9f79de2 || rc=$?
    ;;
  both|all|"")
    fetch_one spi "$SPI_MD5" misterplexd.50f4eb92 || rc=$?
    if [ "$rc" -eq 0 ]; then
      fetch_one ddr "$DDR_MD5" misterplexd.e9f79de2 || rc=$?
    else
      fetch_one ddr "$DDR_MD5" misterplexd.e9f79de2 || true
    fi
    ;;
  *)
    echo "usage: $0 {both|spi|ddr}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac

echo "true rc=$rc"
exit "$rc"
