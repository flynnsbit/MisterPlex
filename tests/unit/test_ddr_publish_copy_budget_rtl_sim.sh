#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
echo "=== test_ddr_publish_copy_budget_rtl_sim EXECUTED ==="
OUT="$ROOT/build/verilator/ddr_publish_copy_budget"
mkdir -p "$OUT"
"$RUN" --cc --exe --build --Mdir "$OUT" \
  --top-module ddr_publish_copy_budget_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_publish_copy_budget_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_publish_copy_budget.sv" \
  "$ROOT/tests/rtl/ddr_publish_copy_budget_tb.cpp"
echo "verilator_build true rc=$?"
set +e
SIM_OUT="$("$OUT/Vddr_publish_copy_budget_tb_top" 2>&1)"
SIM_RC=$?
set -e
printf '%s\n' "$SIM_OUT"
echo "sim true rc=$SIM_RC"
if [[ "$SIM_RC" -ne 0 ]]; then
  echo "FAIL sim rc=$SIM_RC" >&2
  exit "$SIM_RC"
fi
if ! grep -q 'ddr_publish_copy_budget: OK' <<<"$SIM_OUT"; then
  echo "FAIL missing TB OK marker (compile-only is not a pass)" >&2
  exit 2
fi
echo "PASS test_ddr_publish_copy_budget_rtl_sim"
