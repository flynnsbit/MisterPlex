#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "=== test_h264_dpb_wide_fetch_rtl_sim EXECUTED ==="
MDIR="$ROOT/build/verilator/h264_dpb_wide_fetch"
rm -rf "$MDIR"
mkdir -p "$MDIR"
"$ROOT/scripts/run_verilator.sh" --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module h264_dpb_wide_fetch_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -Os" \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/h264_dpb_wide_fetch_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_wide_window_fetch.sv" \
  "$ROOT/tests/rtl/h264_dpb_wide_fetch_tb.cpp"
"$MDIR/Vh264_dpb_wide_fetch_tb_top"; echo "true rc=$?"
echo "OK h264_dpb_wide_fetch: budget NEG byte-serial + wide 99 beats + FAULT 603"
