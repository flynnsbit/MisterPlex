#!/usr/bin/env bash
# Left-edge neighbour availability + delayed I16 start. SKIP is NOT PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not available" >&2
  exit 3
fi
BUILD="$ROOT/build/left_edge_nb"
mkdir -p "$BUILD"
echo "RTL SIM: $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module left_edge_nb_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/left_edge_nb_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_intra_nb_ctx.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_intra_pred.sv" \
  "$ROOT/tests/rtl/left_edge_nb_tb.cpp"
"$BUILD/Vleft_edge_nb_tb_top"
