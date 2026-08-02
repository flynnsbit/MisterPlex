#!/usr/bin/env bash
# Refuse a misterplexd binary that lacks required ship capabilities.
#
# OBSERVED DEFECT (parent, viewed pixels 2026-08-02):
#   Packaged release daemon e9f79de2 + core c5382bee rendered full GREEN field
#   with duplicated/wrapped TREK24 overlay at the user's DECODE=624x480 tier.
#   Live daily-driver daemon emitted `measured=624x350 desync_risk=0` and played
#   correctly. PMS delivers 624x350 for that asset — not 624x480. Every prior
#   gate was green while the packaged binary lacked the delivery-geometry
#   capability the live tree had already shipped on-device.
#
# This check keys on CAPABILITY MARKERS (and optional stamp), never on a
# hard-coded pair of md5s. Markers are string literals that current source
# embeds in the binary (see arm/misterplexd/media_player.cpp delivery ledger).
#
# Usage:
#   daemon_capability_check.sh <path-to-misterplexd>
#   daemon_capability_check.sh --require-stamp <path>
#
# Exit:
#   0 CAPABILITY_OK
#   1 usage / missing file
#   2 CAPABILITY_FAIL missing marker(s)
#   3 STAMP_FAIL (only with --require-stamp)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
require_stamp=0
path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --require-stamp) require_stamp=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      path=$1
      shift
      ;;
  esac
done

if [ -z "${path}" ] || [ ! -f "$path" ]; then
  echo "CAPABILITY_FAIL reason=missing_file path=${path:-}"
  exit 1
fi

sz=$(wc -c <"$path" | tr -d ' ')
if [ "${sz:-0}" -lt 1000 ]; then
  echo "CAPABILITY_FAIL reason=too_small bytes=$sz path=$path"
  exit 1
fi

# Required telemetry / delivery-geometry markers. A build that cannot emit
# these cannot handle measured≠coded bank (parent: 624x350 vs 624x480).
# Keep list small and tied to the observed defect class — not a matrix of
# speculative strings.
REQUIRED_MARKERS=(
  "desync_risk="
  "coded_bank="
  "DELIVERY_MISMATCH_FINAL"
  "measured="
)

md5=$(md5sum "$path" | awk '{print $1}')
echo "daemon_capability path=$path md5=$md5 bytes=$sz require_stamp=$require_stamp"

missing=()
# Binary scan: prefer grep -a (no pipefail/SIGPIPE false-negative when
# strings|grep -q closes the pipe early on a match).
for m in "${REQUIRED_MARKERS[@]}"; do
  if grep -aFq -- "$m" "$path" 2>/dev/null; then
    echo "CAPABILITY_MARKER_OK marker=$m"
  else
    echo "CAPABILITY_MARKER_MISSING marker=$m"
    missing+=("$m")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "CAPABILITY_FAIL reason=missing_markers count=${#missing[@]} md5=$md5"
  echo "MISSING: ${missing[*]}"
  echo "ACTION: rebuild misterplexd from current main (delivery-geometry ledger) and re-pin the release pair; do not ship an older binary that lacks measured/desync_risk telemetry."
  exit 2
fi

if [ "$require_stamp" -eq 1 ]; then
  set +e
  stamp_out=$("$ROOT/scripts/daemon_stamp_check.sh" --require-stamped "$path" 2>&1)
  stamp_rc=$?
  set -e
  printf '%s\n' "$stamp_out"
  if [ "$stamp_rc" -ne 0 ]; then
    echo "CAPABILITY_FAIL reason=stamp_required_failed stamp_rc=$stamp_rc md5=$md5"
    exit 3
  fi
fi

echo "CAPABILITY_OK md5=$md5 markers=${#REQUIRED_MARKERS[@]} stamp_required=$require_stamp"
exit 0
