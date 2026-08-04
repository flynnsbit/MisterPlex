#!/usr/bin/env bash
# Verilator sim for ddr_frame_dma — beat conservation + misalign RED.
# Soft-skip≠PASS. true rc captured directly (never through a pipe).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_dma.sv"
TB="$ROOT/tests/rtl/ddr_frame_dma_tb.cpp"
OUT="$ROOT/build/verilator/ddr_frame_dma"
mkdir -p "$OUT"

echo "=== test_ddr_frame_dma_rtl_sim EXECUTED ==="

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP-NOT-PASS RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "FAIL: verilator missing (rc=127)" >&2
  exit 1
fi
echo "RTL SIM: using $VERILATOR_VERSION (ddr_frame_dma)"

set +e
"$RUN_VERILATOR" -sv -cc --exe --build -Mdir "$OUT" \
  -CFLAGS "-std=c++17 -O2" \
  --top-module ddr_frame_dma \
  "$RTL" "$TB"
BUILD_RC=$?
set -e
if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "FAIL verilator build rc=$BUILD_RC" >&2
  exit "$BUILD_RC"
fi

set +e
OUT_LOG="$("$OUT/Vddr_frame_dma" 2>&1)"
SIM_RC=$?
set -e
echo "$OUT_LOG"
echo "sim true rc=$SIM_RC"
if [[ "$SIM_RC" -ne 0 ]]; then
  echo "FAIL ddr_frame_dma sim" >&2
  exit "$SIM_RC"
fi
if ! grep -q 'PASS ddr_frame_dma_tb' <<<"$OUT_LOG"; then
  echo "FAIL: missing PASS marker (compile-only is not a pass)" >&2
  exit 2
fi
echo "OK test_ddr_frame_dma_rtl_sim"
