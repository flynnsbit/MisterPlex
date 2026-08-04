#!/usr/bin/env bash
# Path (b) fabric frame mem2mem — full 1280x720 RD staging→WE bank+doorbell.
# Parent Sweep-118: retire T_copy_arm=14.978 ms via fabric DMA.
# Direct exit code path; soft-skip only if Verilator missing (lib gate).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
rtl_sim_require_verilator "fabric_ddr_frame_mem2mem"
BUILD_DIR="$ROOT/build/verilator/fabric_ddr_frame_mem2mem_tb"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl --Mdir "$BUILD_DIR" \
  --top-module fabric_ddr_frame_mem2mem_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-SELRANGE -Wno-UNSIGNED -CFLAGS "-std=c++17 -O2" \
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_frame_mem2mem.sv" \
  "$ROOT/tests/rtl/fabric_ddr_frame_mem2mem_tb_top.sv" \
  "$ROOT/tests/rtl/fabric_ddr_frame_mem2mem_tb.cpp"
EXE="$BUILD_DIR/Vfabric_ddr_frame_mem2mem_tb_top"
[[ -x "$EXE" ]] || { echo "FAIL binary missing" >&2; exit 2; }
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "fabric_ddr_frame_mem2mem true rc=$RC"
[[ "$RC" -eq 0 ]] || exit "$RC"
assert_sim_executed "fabric_ddr_frame_mem2mem" "$OUT" \
  "CASE G0_ideal_b0" "CASE G1_busy4_b0" "CASE G2_ideal_b1" \
  "fabric_ddr_frame_mem2mem_tb PASS"
exit 0
