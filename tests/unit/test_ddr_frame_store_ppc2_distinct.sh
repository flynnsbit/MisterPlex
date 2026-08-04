#!/usr/bin/env bash
# Gate: ddr_frame_store PX_PER_CLK=2 emits distinct odd/even pixels (rd-duck FIT BLOCKER).
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

BUILD="$ROOT/build/verilator/ddr_frame_store_ppc2_distinct"
rm -rf "$BUILD"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
echo "PRE-REG: gradient Y; lane0_r != lane1_r on dual-valid samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module ddr_frame_store_ppc2_distinct_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/ddr_frame_store_ppc2_distinct_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_ppc2_distinct_tb.cpp"

EXE="$BUILD/Vddr_frame_store_ppc2_distinct_tb"
if [[ ! -x "$EXE" ]]; then
  echo "FAIL ppc2_distinct: binary missing" >&2
  exit 2
fi
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "$OUT" | grep -q PASS || { echo "FAIL ppc2_distinct: no PASS in TB out" >&2; exit 1; }
echo "ddr_frame_store_ppc2_distinct true rc=$RC"
exit "$RC"
