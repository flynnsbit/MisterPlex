#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_iq_idct_4x4 real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
SKIP
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
TB="$ROOT/tests/rtl/h264_iq_idct_4x4_tb.cpp"
TBTOP="$ROOT/tests/rtl/h264_iq_idct_4x4_tb_top.sv"
FIXTURE="$ROOT/tests/fixtures/p3_host_recon/mb0_luma_v1.json"
BUILD_DIR="$ROOT/build/verilator/h264_iq_idct_4x4"

if [[ ! -f "$RTL" || ! -f "$TB" || ! -f "$FIXTURE" ]]; then
  echo "RTL SIM ERROR: missing RTL, testbench, or fixture" >&2
  echo "  RTL=$RTL" >&2
  echo "  TB=$TB" >&2
  echo "  FIXTURE=$FIXTURE" >&2
  exit 2
fi

mkdir -p "$BUILD_DIR"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DIR" \
  --top-module h264_iq_idct_4x4 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TBTOP" "$RTL" "$TB"
"$BUILD_DIR/Vh264_iq_idct_4x4" "$FIXTURE"
