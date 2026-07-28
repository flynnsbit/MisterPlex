#!/usr/bin/env bash
# Measures whether ddr_frame_store's clk_ddr mailbox telemetry survives the
# failure it exists to report. Deliberately NOT registered in `make unit` while
# it is red: registering a failing gate is how allowlists get born.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing to report a result without running the simulation." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/ddr_frame_store_telemetry_liveness"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module ddr_frame_store_warm_reset_tb -GLINE_COUNT=8 -GSTALE_DOORBELL_FALLBACK_POLLS=256 \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_store_warm_reset_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_telemetry_liveness_tb.cpp"

set +e
"$BUILD/Vddr_frame_store_warm_reset_tb"
SIM_RC=$?
set -e
exit "$SIM_RC"
