#!/usr/bin/env bash
# Long dual-clock CDC soak for present_npx_path (beat + RGB order).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
"$RUN_VERILATOR" --version >/dev/null 2>&1
VRC=$?
set -e
if [[ "$VRC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing" >&2
  exit 77
elif [[ "$VRC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe rc=$VRC" >&2
  exit "$VRC"
fi

OUT="$ROOT/build/verilator/present_npx_cdc_soak"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_npx_cdc_soak_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)

"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_npx_cdc_soak_tb \
  -GPX_PER_CLK=2 -GN_GROUPS=4096 \
  -Mdir "$OUT/green" "${SRCS[@]}" >/dev/null
set +e
"$OUT/green/Vpresent_npx_cdc_soak_tb" >"$OUT/green.log" 2>&1
GRC=$?
set -e
grep -q 'PASS present_npx_cdc_soak' "$OUT/green.log" || {
  cat "$OUT/green.log"
  echo "FAIL cdc soak" >&2
  exit 1
}
echo "OK present_npx_cdc_soak GREEN rc=$GRC"
echo "true rc=$GRC"
echo "PASS test_present_npx_cdc_soak"
