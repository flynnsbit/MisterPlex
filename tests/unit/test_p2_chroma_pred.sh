#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build/p2-chroma-pred"
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
"$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 2 -Wno-fatal \
  --top-module p2_chroma_pred_tb --Mdir "$BUILD/obj" -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/p2_chroma_pred_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_intra_pred.sv" \
  "$ROOT/tests/rtl/p2_chroma_pred_tb.cpp" \
  >"$BUILD/build.log" 2>&1 || { tail -50 "$BUILD/build.log"; exit 1; }
"$BUILD/obj/Vp2_chroma_pred_tb"
