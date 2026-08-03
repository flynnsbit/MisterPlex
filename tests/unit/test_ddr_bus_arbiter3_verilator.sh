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

BUILD_DIR="$ROOT/build/verilator/ddr_bus_arbiter3_tb"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

RTL=(
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter3.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_bank_credit.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_i420_pattern_src.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_writer.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_write_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_attach.sv"
  "$ROOT/tests/rtl/ddr_bus_arbiter3_tb_top.sv"
  "$ROOT/tests/rtl/ddr_bus_arbiter3_tb.cpp"
)

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
  --Mdir "$BUILD_DIR" \
  --top-module ddr_bus_arbiter3_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "${RTL[@]}"

EXE="$BUILD_DIR/Vddr_bus_arbiter3_tb_top"
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_bus_arbiter3_sim true rc=$RC"
exit "$RC"
