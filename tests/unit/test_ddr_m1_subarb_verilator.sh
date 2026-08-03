#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not found or broken; refusing to PASS without simulation." >&2
  exit 3
fi

BUILD_DIR="$ROOT/build/verilator/ddr_m1_subarb_tb"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

RTL=(
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_m1_subarb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plxg_ddr_poller.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv"
  "$ROOT/tests/rtl/ddr_m1_subarb_tb_top.sv"
  "$ROOT/tests/rtl/ddr_m1_subarb_tb.cpp"
)

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
  --Mdir "$BUILD_DIR" \
  --top-module ddr_m1_subarb_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "${RTL[@]}"

source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
EXE="$BUILD_DIR/Vddr_m1_subarb_tb_top"
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_m1_subarb_sim true rc=$RC"
[[ "$RC" -eq 0 ]] || exit "$RC"
assert_sim_executed "ddr_m1_subarb" "$OUT" "ddr_m1_subarb_tb: OK"
exit 0
