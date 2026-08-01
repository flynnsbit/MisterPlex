#!/usr/bin/env bash
# fetch_daemon_pins.sh — PARENT-ONLY: pull matched-pair daemon ELFs from the MiSTer.
#
# Pins are gitignored (large ARM binaries). Rollback/promote require them on the
# host under artifacts/daemon-pins/. This script is the documented fetch step.
#
# Usage (parent; agents must not SSH):
#   scripts/fetch_daemon_pins.sh              # both SPI + DDR pins
#   scripts/fetch_daemon_pins.sh spi          # 50f4eb92 only
#   scripts/fetch_daemon_pins.sh ddr          # live primary (9ce2c2d1)
#   scripts/fetch_daemon_pins.sh 9ce2c2d1     # current glass-verified live
# Host lane-build pin (no SSH): scripts/pin_daemon_artifact.sh <path>
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

# Pins by prefix8 (full md5 verified after fetch). Primary DDR = 9ce2c2d1.
# shellcheck disable=SC2034
SPI_MD5=50f4eb925de10e29172999a565c87684
SPI_PFX=50f4eb92
DDR_HIST_MD5=e9f79de217982aff44207664fdb945c5
DDR_HIST_PFX=e9f79de2
DDR_LIVE_MD5=9ce2c2d13d1c8712683289043e99002c
DDR_LIVE_PFX=9ce2c2d1   # current glass-verified; live /proc/exe is source of truth
DDR_3883_PFX=3883f5ab   # prior live — accepted rollback
DDR_EDC3_PFX=edc3a46b   # accepted rollback pin

fetch_one() {
  local label="$1" want_spec="$2" out_name="$3"
  # want_spec: full md5 OR prefix8 (length 8)
  local out="$OUT/$out_name" found="" remote_list rc host_md5 want_pfx
  want_spec=$(printf '%s' "$want_spec" | tr 'A-F' 'a-f' | tr -cd '0-9a-f')
  want_pfx="${want_spec:0:8}"

  echo "fetch: want $label spec=$want_spec -> $out"

  if [ -f "$out" ]; then
    host_md5=$(md5sum "$out" | awk '{print $1}')
    if [ "${#want_spec}" -ge 32 ] && [ "$host_md5" = "$want_spec" ]; then
      echo "OK host-cache $out md5=$host_md5"
      echo "fetch_$label true rc=0"
      return 0
    fi
    if [ "${#want_spec}" -eq 8 ] && [ "${host_md5:0:8}" = "$want_spec" ]; then
      echo "OK host-cache $out md5=$host_md5 (prefix8 match)"
      echo "fetch_$label true rc=0"
      return 0
    fi
    echo "NOTE host file md5=$host_md5 stale — re-fetch"
  fi

  set +e
  remote_list=$(ssh_m "bash -s" <<EOS
set +e
want=$want_spec
wp=${want_pfx}
# Prefer live /proc exe when prefix matches (ETXTBSY-safe identity).
for d in /proc/[0-9]*; do
  [ -r "\$d/cmdline" ] || continue
  cmd=\$(tr '\\0' ' ' <"\$d/cmdline" 2>/dev/null) || continue
  case "\$cmd" in *plexctl*) continue ;; esac
  case "\$cmd" in */misterplexd\\ *|*/misterplexd) ;; *) continue ;; esac
  exe=\$(readlink -f "\$d/exe" 2>/dev/null) || continue
  [ -f "\$exe" ] || continue
  m=\$(md5sum "\$exe" 2>/dev/null | awk '{print \$1}')
  if [ -n "\$m" ]; then
    if [ "\${#want}" -ge 32 ] && [ "\$m" = "\$want" ]; then echo "\$exe"; exit 0; fi
    if [ "\${m:0:8}" = "\$wp" ]; then echo "\$exe"; exit 0; fi
  fi
done
for p in \\
  /media/fat/misterplex_v2/bin/misterplexd.\\${want_pfx}.bak \\
  /media/fat/misterplex_v2/bin/misterplexd.bak.\\${want_pfx} \\
  /media/fat/misterplex_v2/bin/misterplexd.bak.pre-plxd \\
  /media/fat/misterplex_v2/bin/misterplexd.prev-deploy \\
  /media/fat/misterplex_v2/bin/misterplexd \\
  /media/fat/misterplex/bin/misterplexd.\\${want_pfx}.bak \\
  /media/fat/misterplex/bin/misterplexd.prev-deploy \\
  /media/fat/misterplex/bin/misterplexd \\
  /media/fat/_Utility/misterplexd.\\${want_pfx} \\
  /media/fat/_Utility/misterplexd.$label
do
  [ -f "\$p" ] || continue
  m=\$(md5sum "\$p" 2>/dev/null | awk '{print \$1}')
  [ -n "\$m" ] || continue
  if [ "\${#want}" -ge 32 ]; then
    [ "\$m" = "\$want" ] || continue
  else
    [ "\${m:0:8}" = "\$wp" ] || continue
  fi
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
    echo "FAIL no on-device file matching $want_spec"
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
  if [ "${#want_spec}" -ge 32 ] && [ "$host_md5" != "$want_spec" ]; then
    echo "FAIL host md5 $host_md5 != want $want_spec"
    echo "fetch_$label true rc=3"
    return 3
  fi
  if [ "${#want_spec}" -eq 8 ] && [ "${host_md5:0:8}" != "$want_spec" ]; then
    echo "FAIL host md5 $host_md5 prefix != want $want_spec"
    echo "fetch_$label true rc=3"
    return 3
  fi
  echo "OK fetched $out md5=$host_md5"
  # content-address rename if we only had prefix
  if [ "${out_name}" = "misterplexd.${host_md5:0:8}" ] || true; then
    :
  fi
  file "$out" || true
  echo "fetch_$label true rc=0"
  return 0
}

rc=0
case "$WANT" in
  spi|50f4eb92)
    fetch_one spi "$SPI_MD5" misterplexd.50f4eb92 || rc=$?
    ;;
  hist|e9f79de2|ddr-hist)
    fetch_one ddr_hist "$DDR_HIST_MD5" misterplexd.e9f79de2 || rc=$?
    ;;
  ddr|live|9ce2c2d1|primary)
    fetch_one ddr_live "$DDR_LIVE_MD5" misterplexd.9ce2c2d1 || rc=$?
    ;;
  3883f5ab)
    fetch_one ddr_3883 "$DDR_3883_PFX" misterplexd.3883f5ab || rc=$?
    ;;
  edc3a46b)
    fetch_one ddr_edc3 "$DDR_EDC3_PFX" misterplexd.edc3a46b || rc=$?
    ;;
  both|all|"")
    fetch_one spi "$SPI_MD5" misterplexd.50f4eb92 || rc=$?
    fetch_one ddr_live "$DDR_LIVE_MD5" misterplexd.9ce2c2d1 || rc=$?
    fetch_one ddr_3883 "$DDR_3883_PFX" misterplexd.3883f5ab || true
    fetch_one ddr_edc3 "$DDR_EDC3_PFX" misterplexd.edc3a46b || true
    fetch_one ddr_hist "$DDR_HIST_MD5" misterplexd.e9f79de2 || true
    ;;
  *)
    echo "usage: $0 {both|spi|ddr|live|9ce2c2d1|3883f5ab|edc3a46b|hist|e9f79de2}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac

echo "true rc=$rc"
exit "$rc"
