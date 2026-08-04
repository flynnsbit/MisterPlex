#!/usr/bin/env bash
# Full 1280x720 real ddr_frame_store beat delta @ PPC2 + clk 20:90 (w-clock).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed rc=$VERILATOR_RC" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/ddr_frame_store_720p_ppc2_bus"
rm -rf "$BUILD"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
echo "PRE-REG: steady payload_delta>=172800; 20:90 clocks; PPC=2; LINE=16"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module ddr_frame_store_720p_ppc2_bus_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/ddr_frame_store_720p_ppc2_bus_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_720p_ppc2_bus_tb.cpp"

EXE="$BUILD/Vddr_frame_store_720p_ppc2_bus_tb"
if [[ ! -x "$EXE" ]]; then
  echo "FAIL 720p_ppc2_bus: binary missing" >&2
  exit 2
fi
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_frame_store_720p_ppc2_bus true rc=$RC"
exit "$RC"
