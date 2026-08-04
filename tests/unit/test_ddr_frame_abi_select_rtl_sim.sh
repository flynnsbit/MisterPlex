#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
echo "=== test_ddr_frame_abi_select_rtl_sim EXECUTED ==="
OUT="$ROOT/build/verilator/ddr_frame_abi_select"
mkdir -p "$OUT"
# Includes live next to rtl/; add +incdir
"$RUN" --cc --exe --build --Mdir "$OUT" \
  --top-module ddr_frame_abi_select_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb_top.sv" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb.cpp"
echo "verilator_build true rc=$?"
"$OUT/Vddr_frame_abi_select_tb_top"
echo "sim true rc=$?"
echo "PASS test_ddr_frame_abi_select_rtl_sim"
