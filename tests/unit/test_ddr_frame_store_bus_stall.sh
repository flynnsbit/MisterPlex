#!/usr/bin/env bash
# Real ddr_frame_store L4 DDRAM bus + stall injection (w-mem).
# Replaces false "bandwidth proof" from free-running beat_fire counters.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

rtl_sim_require_verilator "ddr_bus_stall"

BUILD_DIR="$ROOT/build/verilator/ddr_frame_store_bus_stall_tb"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
  --Mdir "$BUILD_DIR" \
  --top-module ddr_frame_store_bus_stall_tb -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bank_geom_guard.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_bus_stall_tb_top.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_bus_stall_tb.cpp"

EXE="$BUILD_DIR/Vddr_frame_store_bus_stall_tb"
if [[ ! -x "$EXE" ]]; then
  echo "FAIL ddr_bus_stall: TB binary missing" >&2
  exit 2
fi
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_frame_store_bus_stall true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL ddr_bus_stall: TB rc=$RC" >&2
  exit "$RC"
fi
assert_sim_executed "ddr_bus_stall" "$OUT" \
  "PASS G0 real_ddr_frame_store" \
  "PASS G1 real_bus_worst_stall" \
  "PASS G2 short_frame_under_24fps_budget" \
  "PASS R0 permanent_busy" \
  "PASS HOST_COST_SEPARATE" \
  "PASS ddr_frame_store_bus_stall all"
exit 0
