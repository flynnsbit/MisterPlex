#!/usr/bin/env bash
# 720p DDR bandwidth meter + bank geom guard (w-mem). Simulation proof.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"

RTL_G="$ROOT/fpga/Plex_MiSTer/rtl/ddr_bank_geom_guard.sv"
RTL_B="$ROOT/fpga/Plex_MiSTer/rtl/ddr_bandwidth_meter.sv"
RTL_S="$ROOT/fpga/Plex_MiSTer/rtl/sdram_line_spill.sv"
RTL_C="$ROOT/fpga/Plex_MiSTer/rtl/ddr_contended_bandwidth.sv"
TOP="$ROOT/tests/rtl/ddr_bw_geom_tb_top.sv"
TB="$ROOT/tests/rtl/ddr_bw_geom_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

rtl_sim_require_verilator "ddr_bw_geom"

BUILD_DIR="$ROOT/build/verilator/ddr_bw_geom_tb"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
  --Mdir "$BUILD_DIR" \
  --top-module ddr_bw_geom_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL_G" "$RTL_B" "$RTL_S" "$RTL_C" "$TOP" "$TB"

EXE="$BUILD_DIR/Vddr_bw_geom_tb_top"
if [[ ! -x "$EXE" ]]; then
  echo "FAIL ddr_bw_geom: TB binary missing: $EXE" >&2
  exit 2
fi
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_bw_geom_sim true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL ddr_bw_geom: TB rc=$RC" >&2
  exit "$RC"
fi
# Static gate + runtime: prove TB executed (compile-only ≠ PASS).
assert_sim_executed "ddr_bw_geom" "$OUT" \
  "PASS G1" "PASS R1" "PASS G2" "PASS R2 rtl_budget_fail" "PASS G3" \
  "PASS G4 contended_rw24" "PASS R3 contended_tiny_budget" "PASS R4 scan_starved" \
  "PASS ddr_bw_geom all"
exit 0
