#!/usr/bin/env bash
# Assert decoder writeback changes ddr_frame_store destination DDR contents.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
  echo "REFUSE: ALLOW_MISSING_VERILATOR=1 is not a pass" >&2
  exit 2
fi
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
export OSS_CAD_SUITE
V="$ROOT/scripts/run_verilator.sh"
BUILD="$ROOT/build/verilator/ddr_frame_store_px_wb"
rm -rf "$BUILD"
mkdir -p "$BUILD"
$V --cc --exe --build -sv -O2 --top-module ddr_frame_store_px_wb_tb \
  -Mdir "$BUILD" -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_store_px_wb_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_px_wb_tb.cpp"
"$BUILD/Vddr_frame_store_px_wb_tb"
