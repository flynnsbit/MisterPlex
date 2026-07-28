#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RC_UNSCORED="${RC_UNSCORED:-77}"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found and ALLOW_MISSING_VERILATOR=1; swap-livelock simulation was NOT run." >&2
    exit "$RC_UNSCORED"
  fi
  echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running swap-livelock simulation." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/ddr_frame_store_swap_livelock"
FAULT_BUILD="$ROOT/build/verilator/ddr_frame_store_swap_livelock_fault"
mkdir -p "$BUILD" "$FAULT_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module ddr_frame_store_warm_reset_tb -GLINE_COUNT=8 -GSTALE_DOORBELL_FALLBACK_POLLS=256 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_store_warm_reset_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_swap_livelock_tb.cpp"
"$BUILD/Vddr_frame_store_warm_reset_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$FAULT_BUILD" \
  --top-module ddr_frame_store_warm_reset_tb -GLINE_COUNT=8 -GSTALE_DOORBELL_FALLBACK_POLLS=256 +define+DDR_FRAME_STORE_FAULT_PREP_INVALID_ONLY -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_store_warm_reset_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_swap_livelock_tb.cpp"
set +e
FAULT_OUT="$($FAULT_BUILD/Vddr_frame_store_warm_reset_tb 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL ddr_frame_store swap-livelock red-check: prep invalid-only fault unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'no third swap' <<<"$FAULT_OUT"; then
  echo "FAIL ddr_frame_store swap-livelock red-check: expected no-third-swap diagnostic" >&2
  exit 1
fi
echo "OK ddr_frame_store swap-livelock red-check: prep invalid-only fault failed naturally"
