#!/usr/bin/env bash
# Full 1280x720 real ddr_frame_store @ PPC2 + clk 20:90 + stalls (w-osd hard blocker).
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
mkdir -p "$BUILD/lc32" "$BUILD/lc8"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
echo "PRE-REG: FULL+STALL @20:90; LC32 GREEN und=0; LC8 teeth RED"

build_one() {
  local dir="$1" lc="$2"
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$dir" \
    --top-module ddr_frame_store_720p_ppc2_bus_tb \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
    -CFLAGS "-std=c++17 -O2" \
    -GLINE_COUNT="$lc" \
    +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
    "$ROOT/tests/rtl/ddr_frame_store_720p_ppc2_bus_tb_top.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
    "$ROOT/tests/rtl/ddr_frame_store_720p_ppc2_bus_tb.cpp"
}

echo "=== LC=32 product floor (expect GREEN full+stall) ==="
build_one "$BUILD/lc32" 32
EXE32="$BUILD/lc32/Vddr_frame_store_720p_ppc2_bus_tb"
set +e
OUT32="$("$EXE32" 2>&1)"
RC32=$?
set -e
printf '%s\n' "$OUT32"
echo "lc32_full_stall true rc=$RC32"
if [[ "$RC32" -ne 0 ]]; then
  echo "FAIL 720p_ppc2_bus LC32" >&2
  exit 1
fi
echo "$OUT32" | grep -q 'G1_full_stall' || { echo "FAIL missing G1_full_stall" >&2; exit 1; }
echo "$OUT32" | grep -q 'underrun_delta=0' || { echo "FAIL expected underrun_delta=0" >&2; exit 1; }
echo "$OUT32" | grep -q 'BEAT_SUMMARY' || { echo "FAIL missing BEAT_SUMMARY" >&2; exit 1; }
echo "$OUT32" | grep -q 'de_groups=460800' || { echo "FAIL expected full-frame de_groups" >&2; exit 1; }

echo "=== LC=8 teeth (expect RED: LC floor or underrun) ==="
build_one "$BUILD/lc8" 8
EXE8="$BUILD/lc8/Vddr_frame_store_720p_ppc2_bus_tb"
set +e
OUT8="$("$EXE8" 2>&1)"
RC8=$?
set -e
printf '%s\n' "$OUT8"
echo "lc8_full_stall true rc=$RC8"
if [[ "$RC8" -eq 0 ]]; then
  echo "FAIL LC8 should not PASS full+stall (teeth)" >&2
  exit 1
fi
echo "OK LC8 RED (teeth) rc=$RC8"

echo "PASS test_ddr_frame_store_720p_ppc2_bus FULL+STALL @20:90"
exit 0
