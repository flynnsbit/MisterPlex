#!/usr/bin/env bash
# PLXC chrome m_gnt+beats + video non-starve + starve red twin (w-mem arbiter).
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

BUILD_DIR="$ROOT/build/verilator/ddr_plxc_grant_tb"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

RTL=(
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_plxc_master_bridge.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter_plxc.sv"
  "$ROOT/tests/rtl/ddr_plxc_grant_tb_top.sv"
  "$ROOT/tests/rtl/ddr_plxc_grant_tb.cpp"
)

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
  --Mdir "$BUILD_DIR" \
  --top-module ddr_plxc_grant_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "${RTL[@]}"

source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
EXE="$BUILD_DIR/Vddr_plxc_grant_tb_top"
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ddr_plxc_grant_sim true rc=$RC"
[[ "$RC" -eq 0 ]] || exit "$RC"
assert_sim_executed "ddr_plxc_grant" "$OUT" "PASS" "ddr_plxc_grant ALL PASS"
exit 0
