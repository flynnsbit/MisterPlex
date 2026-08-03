#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL_W="$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_writer.sv"
RTL_P="$ROOT/fpga/Plex_MiSTer/rtl/fabric_i420_pattern_src.sv"
TOP="$ROOT/tests/rtl/fabric_ddr_writer_tb_top.sv"
TB="$ROOT/tests/rtl/fabric_ddr_writer_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not found or broken; refusing to PASS without simulation." >&2
  exit 3
fi

BUILD_DIR="$ROOT/build/verilator/fabric_ddr_writer_tb"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DIR" \
  --top-module fabric_ddr_writer_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL_W" "$RTL_P" "$TOP" "$TB"

source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
EXE="$BUILD_DIR/Vfabric_ddr_writer_tb_top"
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "fabric_ddr_writer_sim true rc=$RC"
exit "$RC"
