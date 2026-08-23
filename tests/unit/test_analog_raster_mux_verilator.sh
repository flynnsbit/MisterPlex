#!/usr/bin/env bash
# Analog raster mux: 240p 15.6 kHz vs 480p 31 kHz vs 480i field. RED twin required.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL_MUX="$ROOT/fpga/Plex_MiSTer/rtl/analog_raster_mux.sv"
RTL_BARS="$ROOT/fpga/Plex_MiSTer/rtl/colorbars.sv"
TB="$ROOT/tests/rtl/analog_raster_mux_tb.cpp"

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

BUILD="$ROOT/build/verilator/analog_raster_mux"
FAULT_BUILD="$ROOT/build/verilator/analog_raster_mux_fault"
mkdir -p "$BUILD" "$FAULT_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module analog_raster_mux -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL_MUX" "$RTL_BARS" "$TB"
"$BUILD/Vanalog_raster_mux"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$FAULT_BUILD" \
  --top-module analog_raster_mux -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  +define+ANALOG_RASTER_FAULT_SWAP_SEL \
  "$RTL_MUX" "$RTL_BARS" "$TB"
set +e
FAULT_OUT="$("$FAULT_BUILD/Vanalog_raster_mux" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL analog_raster_mux red-check: swapped-sel fault unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'FAIL 240p' <<<"$FAULT_OUT"; then
  echo "FAIL analog_raster_mux red-check: expected 240p class diagnostic" >&2
  exit 1
fi
echo "OK analog_raster_mux red-check: swapped sel failed 15.6 vs 31 kHz class"
