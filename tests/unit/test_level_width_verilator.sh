#!/usr/bin/env bash
# Red-before-green test for coefficient level width truncation.
# Fails on current RTL (signed [8:0] truncation); passes after widening.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
TOP="$ROOT/tests/rtl/level_width_tb_top.sv"
TB="$ROOT/tests/rtl/level_width_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

# Refuse to pass silently if Verilator is absent.
set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not found or broken; refusing to PASS without simulation." >&2
  exit 3
fi

BUILD_DIR="$ROOT/build/verilator/level_width_tb"
mkdir -p "$BUILD_DIR"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DIR" \
  --top-module level_width_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL" "$TOP" "$TB"

# shellcheck source=tests/unit/lib_rtl_sim_gate.sh
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
EXE="$BUILD_DIR/Vlevel_width_tb_top"
set +e
LEVEL_OUT="$("$EXE" 2>&1)"
LEVEL_RC=$?
set -e
printf '%s\n' "$LEVEL_OUT"
echo "level_width_sim true rc=$LEVEL_RC"
if [[ "$LEVEL_RC" -ne 0 ]]; then
  exit "$LEVEL_RC"
fi
assert_sim_executed "level_width" "$LEVEL_OUT" "level_width_tb: PASS"
