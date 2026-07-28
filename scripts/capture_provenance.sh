#!/usr/bin/env bash
# Assert what is ACTUALLY in the FPGA at capture time.
#
# 2026-07-28: a 1800-frame capture verdict was published against bitstream
# `fb4bad84` while the fabric was running the MiSTer MENU core. The md5 of
# /media/fat/_Utility/Plex.rbf was cited as provenance, but that file is what
# would be loaded NEXT, not what is loaded NOW. Loading MENU replaces the Plex
# bitstream entirely, so the capture measured a different design.
#
# A capture is evidence about a bitstream only if CORENAME and the resident RBF
# md5 are asserted at capture time. This prints both, plus the FPGA manager
# state, plus a live PLXD magic read that proves the Plex fabric is actually
# publishing. Bracket a capture with two calls (before and after) and require
# them to match; a core change mid-window invalidates the clip.
#
# Usage:
#   ./scripts/capture_provenance.sh                 # print a provenance record
#   ./scripts/capture_provenance.sh --expect-core Plex --expect-md5 3b1e8435
#
# Exit codes
#   0   provenance read and any --expect assertions hold
#   1   an --expect assertion failed (wrong core or wrong bitstream loaded)
#   77  device unreachable / provenance UNKNOWN — never treat as a pass
set -uo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
EXPECT_CORE=""
EXPECT_MD5=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-core) EXPECT_CORE="${2:-}"; shift 2 ;;
    --expect-md5)  EXPECT_MD5="${2:-}";  shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$USER@$HOST")

echo "Scope: 1 provenance snapshot host=${HOST} local_time=$(date '+%F %T')"

OUT=$("${SSH[@]}" '
  echo "dev_time=$(date "+%F %T")"
  echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
  echo "corename=$(cat /tmp/CORENAME 2>/dev/null | tr -d "\0\r\n")"
  echo "rbf_on_disk_md5=$(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -d" " -f1)"
  echo "fpga_state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null)"
  echo "daemon_pid=$(pidof misterplexd 2>/dev/null)"
  echo "plxd_magic=$(devmem 0x300FF128 32 2>/dev/null)"
' 2>/dev/null)
rc=$?

if [[ $rc -ne 0 || -z "$OUT" ]]; then
  echo "UNSCORED: device unreachable (ssh rc=$rc); provenance UNKNOWN." >&2
  echo "UNSCORED: a capture taken now cannot be attributed to any bitstream." >&2
  exit 77
fi

echo "$OUT"

get() { echo "$OUT" | sed -n "s/^$1=//p"; }
CORE="$(get corename)"
MD5="$(get rbf_on_disk_md5)"
FPGA="$(get fpga_state)"
MAGIC="$(get plxd_magic)"

# The on-disk md5 is only provenance for the LOADED design when the loaded core
# is Plex. Say so explicitly rather than letting a reader assume it.
if [[ "$CORE" == "Plex" ]]; then
  echo "LOADED_DESIGN: Plex, so rbf_on_disk_md5=${MD5:0:8} describes the running fabric"
  if [[ "$MAGIC" == "0x504C5844" ]]; then
    echo "FABRIC_LIVE: PLXD magic present at 0x300FF128 — the Plex fabric is publishing"
  else
    echo "FABRIC_QUIET: PLXD magic=${MAGIC:-none} (expected 0x504C5844)"
  fi
else
  echo "LOADED_DESIGN: ${CORE:-UNKNOWN} — NOT Plex."
  echo "PROVENANCE_WARNING: rbf_on_disk_md5 describes a file that is NOT loaded."
  echo "PROVENANCE_WARNING: a capture taken now is evidence about ${CORE:-UNKNOWN}, not about Plex."
fi

verdict=0
if [[ -n "$EXPECT_CORE" ]]; then
  if [[ "$CORE" == "$EXPECT_CORE" ]]; then
    echo "EXPECT_CORE_OK: $CORE"
  else
    echo "EXPECT_CORE_FAIL: wanted '$EXPECT_CORE', fabric is running '${CORE:-UNKNOWN}'"
    verdict=1
  fi
fi
if [[ -n "$EXPECT_MD5" ]]; then
  if [[ "$MD5" == "$EXPECT_MD5"* ]]; then
    echo "EXPECT_MD5_OK: ${MD5:0:8}"
  else
    echo "EXPECT_MD5_FAIL: wanted '${EXPECT_MD5:0:8}', on disk is '${MD5:0:8}'"
    verdict=1
  fi
fi

[[ "$FPGA" == "operating" ]] || echo "NOTE: fpga_manager state='${FPGA:-UNKNOWN}' (expected 'operating')"
exit "$verdict"
