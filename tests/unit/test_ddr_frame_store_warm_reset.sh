#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found and ALLOW_MISSING_VERILATOR=1; DDR warm-reset simulation was NOT run." >&2
    exit 0
  fi
  cat >&2 <<'ERR'
RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation.
A skipped RTL gate is NOT a pass. Set ALLOW_MISSING_VERILATOR=1 only if you accept that RTL was never verified.
ERR
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/ddr_frame_store_warm_reset"
FAULT_BUILD="$ROOT/build/verilator/ddr_frame_store_warm_reset_fault"
mkdir -p "$BUILD" "$FAULT_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module ddr_frame_store_warm_reset_tb -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_store_warm_reset_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_warm_reset_tb.cpp"
"$BUILD/Vddr_frame_store_warm_reset_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$FAULT_BUILD" \
  --top-module ddr_frame_store_warm_reset_tb -GIGNORE_STALE_DOORBELL_AFTER_RESET=0 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_store_warm_reset_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_warm_reset_tb.cpp"
set +e
FAULT_OUT="$("$FAULT_BUILD/Vddr_frame_store_warm_reset_tb" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL ddr_frame_store warm-reset red-check: stale-doorbell fault unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'accepted stale doorbell' <<<"$FAULT_OUT"; then
  echo "FAIL ddr_frame_store warm-reset red-check: expected stale-doorbell diagnostic" >&2
  exit 1
fi
echo "OK ddr_frame_store warm-reset red-check: stale-doorbell fault failed"
