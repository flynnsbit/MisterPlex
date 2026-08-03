#!/usr/bin/env bash
# Thin wrapper — parent one-liner after fit.
# Usage:
#   scripts/l4_sta_onepass.sh /path/to/Plex.sta.rpt
#   scripts/l4_sta_onepass.sh /path/to/Plex.sta.rpt /path/to/clk_sys_sameclk_setup.txt
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 STA_RPT [PATH_DUMP]" >&2
  exit 2
fi
STA="$1"
DUMP_ARGS=()
if [[ $# -eq 2 ]]; then
  DUMP_ARGS=(--path-dump "$2")
fi
exec python3 "$ROOT/scripts/l4_sta_onepass.py" \
  --sta-rpt "$STA" \
  "${DUMP_ARGS[@]}" \
  --clk-sys-min-mhz 20.0 \
  --clk-ddr-min-mhz 90.0
