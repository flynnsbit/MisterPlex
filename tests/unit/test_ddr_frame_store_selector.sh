#!/usr/bin/env bash
# Executable RTL bank-selector oracle (rd-duck: not host-only / not source-grep).
# A) FAULT FORCE_LEGACY_BANK_MAP → 960x540 stays legacy (REPRO_OK)
# B) PRODUCT capacity>usable → Option-C + U@518400 + w%16 reject
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: sim did not EXECUTE expected marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL $label: compile-only or empty run is not a pass" >&2
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
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

FAULT_BUILD="$ROOT/build/verilator/ddr_selector_fault"
GOOD_BUILD="$ROOT/build/verilator/ddr_selector_good"
mkdir -p "$FAULT_BUILD" "$GOOD_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_selector_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_selector_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_selector_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== A) FAULT: FORCE_LEGACY_BANK_MAP (expect REPRO_OK legacy on 960x540) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$FAULT_BUILD" \
  -DDDR_FRAME_STORE_FAULT_FORCE_LEGACY_BANK_MAP \
  "${common_sv[@]}"
set +e
FAULT_OUT="$(SELECTOR_MODE=fault "$FAULT_BUILD/Vddr_frame_store_selector_tb" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
echo "fault rc=$FAULT_RC"

echo "=== B) GOOD: capacity usable selector (expect PASS Option-C 960) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  "${common_sv[@]}"
set +e
GOOD_OUT="$(SELECTOR_MODE=good "$GOOD_BUILD/Vddr_frame_store_selector_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "good rc=$GOOD_RC"

assert_sim_executed "selector-fault" "$FAULT_OUT" "REPRO_OK" "selector_fault" "960x540"
assert_sim_executed "selector-good" "$GOOD_OUT" "PASS selector_product" "U@518400" "w%16 reject"

if [[ "$FAULT_RC" -ne 0 ]] || ! grep -q 'REPRO_OK' <<<"$FAULT_OUT"; then
  echo "FAIL: fault twin did not reproduce forced-legacy on 960x540" >&2
  exit 1
fi
if [[ "$GOOD_RC" -ne 0 ]] || ! grep -q 'PASS selector_product' <<<"$GOOD_OUT"; then
  echo "FAIL: product selector oracle did not pass" >&2
  exit 1
fi
echo "OK ddr_frame_store_selector: REPRO_OK fault + PASS product (TB executed)"
exit 0
