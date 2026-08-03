#!/usr/bin/env bash
# Bresenham pixel-rate match for clk_pix PLL path (no device).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="${VERILATOR:-}"
if [[ -z "$RUN_VERILATOR" ]]; then
  if [[ -x "$ROOT/scripts/run_verilator.sh" ]]; then
    RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
  elif command -v verilator >/dev/null 2>&1; then
    RUN_VERILATOR="$(command -v verilator)"
  fi
fi
if [[ -z "${RUN_VERILATOR}" ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
fi

OUT="$ROOT/build/verilator/present_pix_rate_match"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_pix_rate_match_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_pix_rate_match.sv"
)

echo "RTL SIM: $($RUN_VERILATOR --version 2>&1 | head -1)"
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_pix_rate_match_tb \
  -Mdir "$OUT" "${SRCS[@]}" >/dev/null
set +e
"$OUT/Vpresent_pix_rate_match_tb" >"$OUT/log.txt" 2>&1
rc=$?
set -e
grep -q 'PASS present_pix_rate_match' "$OUT/log.txt" || {
  cat "$OUT/log.txt"
  echo "FAIL present_pix_rate_match" >&2
  exit 1
}
echo "PASS test_present_pix_rate_match true rc=$rc"
exit 0
