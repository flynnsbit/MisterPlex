#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
MODE="${1:-all}"
[[ "$MODE" == all || "$MODE" == synthetic ]] || { echo "expected all or synthetic" >&2; exit 2; }
BUILD="$ROOT/build/verilator/h264_deblock_frame"
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
bash scripts/run_verilator.sh --cc --exe --build -j 1 -Wno-fatal \
  --Mdir "$BUILD" --top-module h264_deblock_frame \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/host" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock_frame.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/tests/rtl/h264_deblock_frame_tb.cpp" > "$BUILD/build.log" 2>&1 || {
    cat "$BUILD/build.log"; exit 1;
  }
"$BUILD/Vh264_deblock_frame"
if [[ "$MODE" == all ]]; then
  python3 "$ROOT/tests/unit/h264_deblock_frame_vectors.py" "$BUILD"
fi
