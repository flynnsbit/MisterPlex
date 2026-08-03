#!/usr/bin/env bash
# Product M2 quantum preemption + FAULT sticky-no-quantum red twin (rd-duck).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not found or broken" >&2
  exit 3
fi
echo "RTL SIM: using $VERILATOR_VERSION" >&2

COMMON=(
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter3.sv"
  "$ROOT/tests/rtl/ddr_bus_arbiter3_quantum_tb_top.sv"
  "$ROOT/tests/rtl/ddr_bus_arbiter3_quantum_tb.cpp"
)
VFLAGS=(--cc --exe --build --top-module ddr_bus_arbiter3_quantum_tb_top
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
  -CFLAGS "-std=c++17 -O2")

GOOD_BUILD="$ROOT/build/verilator/ddr_arb3_quantum_good"
FAULT_BUILD="$ROOT/build/verilator/ddr_arb3_quantum_fault"
mkdir -p "$GOOD_BUILD" "$FAULT_BUILD"

echo "=== A) FAULT sticky no-quantum (expect REPRO_OK) ===" >&2
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" "${VFLAGS[@]}" \
  --Mdir "$FAULT_BUILD" \
  -DDDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM \
  "${COMMON[@]}"
set +e
FAULT_OUT="$(ARB3_QMODE=fault "$FAULT_BUILD/Vddr_bus_arbiter3_quantum_tb_top" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
echo "fault true rc=$FAULT_RC"
if ! grep -q "REPRO_OK" <<<"$FAULT_OUT"; then
  echo "FAIL fault twin missing REPRO_OK" >&2
  exit 2
fi
if [[ "$FAULT_RC" -ne 0 ]]; then
  echo "FAIL fault twin rc=$FAULT_RC (REPRO must exit 0)" >&2
  exit 2
fi

echo "=== B) PRODUCT quantum preemption (expect OK interleaved) ===" >&2
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" "${VFLAGS[@]}" \
  --Mdir "$GOOD_BUILD" \
  "${COMMON[@]}"
set +e
GOOD_OUT="$(ARB3_QMODE=product "$GOOD_BUILD/Vddr_bus_arbiter3_quantum_tb_top" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "product true rc=$GOOD_RC"
if ! grep -q "OK arb3 quantum" <<<"$GOOD_OUT"; then
  echo "FAIL product missing OK marker" >&2
  exit 2
fi
if [[ "$GOOD_RC" -ne 0 ]]; then
  echo "FAIL product rc=$GOOD_RC" >&2
  exit "$GOOD_RC"
fi

echo "OK test_ddr_bus_arbiter3_quantum"
exit 0
