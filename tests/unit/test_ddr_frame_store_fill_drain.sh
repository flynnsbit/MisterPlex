#!/usr/bin/env bash
# Fill-drain protocol: product drains accepted beats; FAULT force-IDLE REPROs.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: missing marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 2
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  exit "$VERILATOR_RC"
fi

FAULT_BUILD="$ROOT/build/verilator/ddr_fill_drain_fault"
GOOD_BUILD="$ROOT/build/verilator/ddr_fill_drain_good"
mkdir -p "$FAULT_BUILD" "$GOOD_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_fill_drain_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_fill_drain_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_fill_drain_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== A) FAULT_NO_FILL_DRAIN (expect REPRO rc=2) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$FAULT_BUILD" \
  -DDDR_FRAME_STORE_FAULT_NO_FILL_DRAIN \
  -CFLAGS "-std=c++17 -O2 -DDDR_FRAME_STORE_FAULT_NO_FILL_DRAIN" \
  "${common_sv[@]}"
set +e
FAULT_OUT="$(FILL_DRAIN_MODE=fault "$FAULT_BUILD/Vddr_frame_store_fill_drain_tb" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
echo "fault true rc=$FAULT_RC"

echo "=== B) PRODUCT fill drain (expect PASS rc=0) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  "${common_sv[@]}"
set +e
GOOD_OUT="$(FILL_DRAIN_MODE=good "$GOOD_BUILD/Vddr_frame_store_fill_drain_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "good true rc=$GOOD_RC"

assert_sim_executed "fill-drain-fault" "$FAULT_OUT" "REPRO"
assert_sim_executed "fill-drain-good" "$GOOD_OUT" "PASS fill_drain product" "ISSUE_preaccept"

if [[ "$FAULT_RC" -ne 2 ]]; then
  echo "FAIL: fault twin expected true rc=2 got $FAULT_RC" >&2
  exit 1
fi
if [[ "$GOOD_RC" -ne 0 ]]; then
  echo "FAIL: product fill drain expected true rc=0 got $GOOD_RC" >&2
  exit 1
fi
echo "OK ddr_frame_store_fill_drain: REPRO fault + PASS product"
exit 0
