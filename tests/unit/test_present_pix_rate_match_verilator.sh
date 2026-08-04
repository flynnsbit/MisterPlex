#!/usr/bin/env bash
# Gate: present_pix_rate_match averages CEA 29.7 Mpix/s at clk_sys=20, PPC=2.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
MDIR="$ROOT/build/verilator/present_pix_rate_match"
mkdir -p "$MDIR"
echo "PRE-REG: 200k cycles → ~148500 fires → ~29.7 Mpix/s"
verilator --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module present_pix_rate_match_tb_top \
  -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/present_pix_rate_match_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_pix_rate_match.sv" \
  "$ROOT/tests/rtl/present_pix_rate_match_tb.cpp"
"$MDIR/Vpresent_pix_rate_match_tb_top"
echo "present_pix_rate_match Verilator gate PASS"
