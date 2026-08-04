#!/usr/bin/env bash
# Gate: fabric clock stamp matches product-default Hz / wall flags.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
MDIR="$ROOT/build/verilator/plex_clk_status"
mkdir -p "$MDIR"
echo "PRE-REG: product default sys=20e6 cea_fast=1 l4_fast=1 peak_x10=200"
verilator --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module plex_clk_status_tb_top \
  -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/plex_clk_status_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_clk_status.sv" \
  "$ROOT/tests/rtl/plex_clk_status_tb.cpp"
"$MDIR/Vplex_clk_status_tb_top"
echo "plex_clk_status Verilator gate PASS"
