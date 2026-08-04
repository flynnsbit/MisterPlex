#!/usr/bin/env bash
# Path (b) concurrent: ddr_bus_arbiter3 m0 RD + m2 mem2mem RD/WE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
rtl_sim_require_verilator "fabric_mem2mem_arb_conc"
BUILD_DIR="$ROOT/build/verilator/fabric_mem2mem_arb_conc_tb"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl --Mdir "$BUILD_DIR" \
  --top-module fabric_mem2mem_arb_conc_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-SELRANGE -Wno-UNSIGNED -CFLAGS "-std=c++17 -O2" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter3.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_frame_mem2mem.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_mem2mem_attach.sv" \
  "$ROOT/tests/rtl/fabric_mem2mem_arb_conc_tb_top.sv" \
  "$ROOT/tests/rtl/fabric_mem2mem_arb_conc_tb.cpp"
EXE="$BUILD_DIR/Vfabric_mem2mem_arb_conc_tb_top"
[[ -x "$EXE" ]] || { echo "FAIL binary missing" >&2; exit 2; }
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "fabric_mem2mem_arb_conc true rc=$RC"
[[ "$RC" -eq 0 ]] || exit "$RC"
assert_sim_executed "fabric_mem2mem_arb_conc" "$OUT" \
  "CASE G0_solo_m2" "CASE G1_m0_contend_M2_OVER_M0" "fabric_mem2mem_arb_conc_tb PASS"
exit 0
