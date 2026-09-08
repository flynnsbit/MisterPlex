#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$ROOT/build/verilator/stream_au_frontend"
mkdir -p "$BUILD_ROOT"
sha256sum \
  "$ROOT/tests/rtl/stream_au_frontend_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/nalu_scanner.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_slice_rbsp_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/bitstream_fifo.sv" \
  "$ROOT/tests/rtl/stream_au_frontend_tb.cpp" > "$BUILD_ROOT/inputs.sha256"
for addr_w in 13; do
BUILD="$BUILD_ROOT/addr-$addr_w"
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
"$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 1 \
  --Mdir "$BUILD" --top-module stream_au_frontend_tb -Wno-fatal \
  -GRBSP_ADDR_W="$addr_w" -CFLAGS "-std=c++17 -O2 -DTEST_RBSP_ADDR_W=$addr_w -DTEST_STAGING_BYTES=32768" \
  "$ROOT/tests/rtl/stream_au_frontend_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/nalu_scanner.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_slice_rbsp_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/bitstream_fifo.sv" \
  "$ROOT/tests/rtl/stream_au_frontend_tb.cpp"
"$BUILD/Vstream_au_frontend_tb"
sha256sum --check --status "$BUILD_ROOT/inputs.sha256"
sha256sum "$BUILD/Vstream_au_frontend_tb" > "$BUILD/binary.sha256"
done
