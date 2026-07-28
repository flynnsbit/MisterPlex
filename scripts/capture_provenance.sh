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
  echo "rbf_mtime_epoch=$(date -r /media/fat/_Utility/Plex.rbf +%s 2>/dev/null)"
  echo "core_load_epoch=$(date -r /tmp/CORENAME +%s 2>/dev/null)"
  echo "rbf_mtime=$(date -r /media/fat/_Utility/Plex.rbf "+%F %T" 2>/dev/null)"
  echo "core_load_time=$(date -r /tmp/CORENAME "+%F %T" 2>/dev/null)"
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
  # There is no bitstream readback and no fabric-published build ID, so the
  # identity of the RUNNING design can only be established by ordering: the
  # load reads whatever bytes were on disk at load time. If the RBF was
  # rewritten AFTER the core was loaded, its md5 describes bytes that are NOT
  # in the fabric, and every attribution made from it is wrong.
  # (Technique adopted from W-E2E-O5's fabric_provenance probe.)
  RBF_T="$(get rbf_mtime_epoch)"; LOAD_T="$(get core_load_epoch)"
  if [[ -z "$RBF_T" || -z "$LOAD_T" ]]; then
    echo "ORDER_UNSCORED: missing mtimes (rbf='$RBF_T' load='$LOAD_T');"
    echo "ORDER_UNSCORED: cannot prove the fabric was configured from these bytes."
    ORDER_OK=unknown
  elif (( LOAD_T >= RBF_T )); then
    echo "LOAD_AFTER_WRITE: core loaded $((LOAD_T-RBF_T))s after the RBF was written"
    echo "LOADED_DESIGN: Plex, so rbf_on_disk_md5=${MD5:0:8} describes the running fabric"
    ORDER_OK=yes
  else
    echo "STALE_BINDING: RBF was rewritten $((RBF_T-LOAD_T))s AFTER the core was loaded."
    echo "STALE_BINDING: rbf_on_disk_md5=${MD5:0:8} does NOT describe the running fabric."
    echo "STALE_BINDING: the fabric still holds the PREVIOUS bitstream; reload before attributing."
    ORDER_OK=no
  fi
  if [[ "$MAGIC" == "0x504C5844" ]]; then
    echo "FABRIC_LIVE: PLXD magic present at 0x300FF128 — the Plex fabric is publishing"
  else
    echo "FABRIC_QUIET: PLXD magic=${MAGIC:-none} (expected 0x504C5844)"
  fi
else
  ORDER_OK=n/a
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
  if [[ "$MD5" != "$EXPECT_MD5"* ]]; then
    echo "EXPECT_MD5_FAIL: wanted '${EXPECT_MD5:0:8}', on disk is '${MD5:0:8}'"
    verdict=1
  elif [[ "$ORDER_OK" == "no" ]]; then
    # The bytes match, but they were written after the load, so they are not the
    # bytes in the fabric. Matching an md5 here would be a false attribution.
    echo "EXPECT_MD5_FAIL: on-disk md5 matches '${MD5:0:8}' but STALE_BINDING applies —"
    echo "EXPECT_MD5_FAIL: those bytes were written after the load and are NOT in the fabric."
    verdict=1
  elif [[ "$ORDER_OK" == "n/a" ]]; then
    # Core is not Plex. The file matches, but it is not the loaded design, so an
    # md5 "OK" here would be a false attribution — the exact fb4bad84 error.
    echo "EXPECT_MD5_FAIL: file matches '${MD5:0:8}' but the loaded core is '${CORE:-UNKNOWN}',"
    echo "EXPECT_MD5_FAIL: not Plex — this md5 is not provenance for the running fabric."
    verdict=1
  elif [[ "$ORDER_OK" == "unknown" ]]; then
    echo "EXPECT_MD5_UNSCORED: md5 matches '${MD5:0:8}' but load ordering is unprovable."
    verdict=77
  else
    echo "EXPECT_MD5_OK: ${MD5:0:8} (and the fabric was configured from these bytes)"
  fi
fi

[[ "$FPGA" == "operating" ]] || echo "NOTE: fpga_manager state='${FPGA:-UNKNOWN}' (expected 'operating')"
exit "$verdict"
