#!/usr/bin/env bash
# want_y CDC glitch injection: does a multi-bit glitch on the want_y
# crossing reproduce the frozen-screen signature (has_frame=0)?
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP: Verilator not found" >&2; exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "ERROR: Verilator probe failed" >&2; exit "$VERILATOR_RC"
fi

TOP="$ROOT/tests/rtl/ddr_frame_store_want_y_glitch_tb_top.sv"
TB="$ROOT/tests/rtl/ddr_frame_store_want_y_glitch_tb.cpp"
RTL=(
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)
BUILD="$ROOT/build/verilator/want_y_glitch"

echo "RTL SIM: using $VERILATOR_VERSION" >&2

mkdir -p "$BUILD"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module ddr_frame_store_want_y_glitch_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"

# Run 1: clean baseline (no glitch)
echo ""
echo "=== BASELINE (no glitch) ==="
CLEAN_OUT="$(INJECT_GLITCH=0 "$BUILD/Vddr_frame_store_want_y_glitch_tb" 2>&1)"
CLEAN_RC=$?
echo "$CLEAN_OUT"

# Run 2: with glitch injection
echo ""
echo "=== FAULT INJECTION (want_y glitch every ~37 ticks) ==="
FAULT_OUT="$(INJECT_GLITCH=1 "$BUILD/Vddr_frame_store_want_y_glitch_tb" 2>&1)"
FAULT_RC=$?
echo "$FAULT_OUT"

# Analysis
echo ""
echo "=== COMPARISON ==="
echo "Baseline rc=$CLEAN_RC"
echo "Fault    rc=$FAULT_RC"

if [[ "$CLEAN_RC" -eq 0 && "$FAULT_RC" -ne 0 ]]; then
  echo "RESULT: want_y glitch REPRODUCES frozen-screen signature"
  echo "  Baseline: healthy; Fault injection: stalled or degraded"
  echo "  This is a candidate RCA for the silicon freeze."
elif [[ "$CLEAN_RC" -eq 0 && "$FAULT_RC" -eq 0 ]]; then
  echo "RESULT: want_y glitch does NOT reproduce frozen screen"
  echo "  Both runs healthy. want_y is a CDC hygiene fix, not RCA."
  echo "  Re-elevate other candidates."
elif [[ "$CLEAN_RC" -ne 0 ]]; then
  echo "RESULT: INCONCLUSIVE — baseline itself failed"
  echo "  Debug the baseline before interpreting the fault run."
fi
