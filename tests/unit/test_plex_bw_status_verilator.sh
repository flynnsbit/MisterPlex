#!/usr/bin/env bash
# Gate: fabric BW stamp = 33.1776 MB/s/dir (33177600 B/s), NACK DE-peak as DDR.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
MDIR="$ROOT/build/verilator/plex_bw_status"
mkdir -p "$MDIR"
echo "PRE-REG: dir_bps=33177600 beats=172800 rw=345600 ppc=2 nack=1"
verilator --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module plex_bw_status_tb_top \
  -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_bw_status.sv" \
  "$ROOT/tests/rtl/plex_bw_status_tb_top.sv" \
  "$ROOT/tests/rtl/plex_bw_status_tb.cpp"
"$MDIR/Vplex_bw_status_tb_top"
echo "plex_bw_status Verilator gate PASS"
