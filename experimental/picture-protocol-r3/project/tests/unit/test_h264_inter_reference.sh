#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build/verilator/h264_inter_reference"
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
# One compiler job: safe alongside the fleet's other sole compile slot.
bash scripts/run_verilator.sh --cc --exe --build -j 1 -Wno-fatal \
  --Mdir "$BUILD" --top-module h264_inter_reference_tb \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/h264_inter_reference_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_pred.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/tests/rtl/h264_inter_reference_tb.cpp" > "$BUILD/build.log" 2>&1 || {
    cat "$BUILD/build.log"; exit 1;
  }
"$BUILD/Vh264_inter_reference_tb"
