#!/usr/bin/env bash
# Full 1280x720 real-reader beat delta @ PPC=2, 20:90, stalls (w-mem / rd-duck).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
rtl_sim_require_verilator "ddr_ppc2_fullframe_beats"
BUILD_DIR="$ROOT/build/verilator/ddr_ppc2_fullframe_beats_tb"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl --Mdir "$BUILD_DIR" \
  --top-module ddr_ppc2_fullframe_beats_tb -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Wno-SELRANGE -Wno-UNSIGNED -CFLAGS "-std=c++17 -O2" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bank_geom_guard.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv" \
  "$ROOT/tests/rtl/ddr_ppc2_fullframe_beats_tb_top.sv" \
  "$ROOT/tests/rtl/ddr_ppc2_fullframe_beats_tb.cpp"
EXE="$BUILD_DIR/Vddr_ppc2_fullframe_beats_tb"
[[ -x "$EXE" ]] || { echo "FAIL binary missing" >&2; exit 2; }
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_ppc2_fullframe_beats true rc=$RC"
[[ "$RC" -eq 0 ]] || exit "$RC"
assert_sim_executed "ddr_ppc2_fullframe_beats" "$OUT" \
  "PASS G0 full720" "PASS G1 full720" \
  "PASS HOST_COST_SEPARATE" "PASS ddr_ppc2_fullframe_beats all"
exit 0
