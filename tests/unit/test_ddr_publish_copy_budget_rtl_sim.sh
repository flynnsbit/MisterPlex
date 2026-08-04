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
"$OUT/Vddr_publish_copy_budget_tb_top"
echo "sim true rc=$?"
echo "PASS test_ddr_publish_copy_budget_rtl_sim"
