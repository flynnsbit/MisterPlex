#!/usr/bin/env bash
# One-pass STA interrogation for the single fit slot.
#
# Usage:
#   scripts/sta_onepass_interrogation.sh STA_RPT
#   scripts/sta_onepass_interrogation.sh STA_RPT PATH_DUMP
#   scripts/sta_onepass_interrogation.sh STA_RPT --path-dir DIR
#
# Capture:  scripts/sta_onepass_interrogation.sh ... ; echo "true rc=$?"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/scripts/sta_onepass_interrogation.py"
if [[ $# -lt 1 ]]; then
  echo "usage: $0 STA_RPT [PATH_DUMP|--path-dir DIR]..." >&2
  exit 2
fi
STA="$1"
shift
EXTRA=()
if [[ $# -gt 0 ]]; then
  if [[ "$1" == "--path-dir" ]]; then
    EXTRA=(--path-dir "$2")
  elif [[ "$1" == --* ]]; then
    EXTRA=("$@")
  else
    EXTRA=(--path-dump "$1")
    shift
    while [[ $# -gt 0 ]]; do
      EXTRA+=(--path-dump "$1")
      shift
    done
  fi
fi
exec python3 "$PY" --sta-rpt "$STA" "${EXTRA[@]}" \
  --clk-sys-min-mhz 20.0 --clk-ddr-min-mhz 90.0
