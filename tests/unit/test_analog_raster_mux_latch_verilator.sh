#!/usr/bin/env bash
# Analog mux v1 reset-latch: live fstart sel change must not retarget H class.
# Separate from test_analog_raster_mux_verilator.sh (class GREEN stays green).
# Expected RED on current analog_raster_mux.sv until w-fpga. rc=1 is not PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL_MUX="$ROOT/fpga/Plex_MiSTer/rtl/analog_raster_mux.sv"
RTL_BARS="$ROOT/fpga/Plex_MiSTer/rtl/colorbars.sv"
TB="$ROOT/tests/rtl/analog_raster_mux_latch_tb.cpp"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/analog_raster_mux_latch"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module analog_raster_mux -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL_MUX" "$RTL_BARS" "$TB"

set +e
"$BUILD/Vanalog_raster_mux"
LATCH_RC=$?
set -e
echo "analog_raster_mux_latch true rc=$LATCH_RC"
if [[ "$LATCH_RC" -ne 0 ]]; then
  echo "analog_raster_mux_latch RED/BLOCKED until w-fpga reset-only sel_lat (not PASS)" >&2
fi
exit "$LATCH_RC"
