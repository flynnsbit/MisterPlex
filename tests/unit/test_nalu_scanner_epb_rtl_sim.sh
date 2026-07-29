#!/usr/bin/env bash
# Product-path EPB strip proof for nalu_scanner (VCL tap).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
export OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP RTL SIM: Verilator not found; nalu_scanner EPB was NOT run." >&2
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing PASS without simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

cd "$ROOT"
BUILD="$ROOT/build/verilator/nalu_scanner_epb"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module nalu_scanner_epb_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  tests/rtl/nalu_scanner_epb_tb_top.sv \
  fpga/Plex_MiSTer/rtl/bitstream_fifo.sv \
  fpga/Plex_MiSTer/rtl/nalu_scanner.sv \
  tests/rtl/nalu_scanner_epb_tb.cpp

FIXTURE="$ROOT/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264"
INTER="$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264"
"$BUILD/Vnalu_scanner_epb_tb_top" "$FIXTURE" "$INTER"
echo "test_nalu_scanner_epb_rtl_sim: OK"