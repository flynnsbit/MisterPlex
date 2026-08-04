#!/usr/bin/env bash
# Tear-free bank swap @ 720p-ratio geometry.
# A) product sticky+recycle → PASS mono-bank multi-frame + late + never + no-publish
# B) FAULT_MID_FRAME_SWAP → PASS only if tear checker DETECTS tears (non-tautological)
# Soft-skip (77) is NOT a pass. Assert TB EXECUTED markers.
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

GOOD_BUILD="$ROOT/build/verilator/ddr_bank_swap_tear_good"
FAULT_BUILD="$ROOT/build/verilator/ddr_bank_swap_tear_fault"
mkdir -p "$GOOD_BUILD" "$FAULT_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_bank_swap_tear_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/mplex_hold_lcell.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_bank_swap_tear_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_bank_swap_tear_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl"
  -CFLAGS "-std=c++17 -O2")

echo "=== A) PRODUCT (expect PASS mono-bank / late / never / no-publish) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=1 -GPREP_SLOT_RECYCLE=1 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1 \
  "${common_sv[@]}"
set +e
GOOD_OUT="$("$GOOD_BUILD/Vddr_frame_store_bank_swap_tear_tb" all_product 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "product rc=$GOOD_RC"

echo "=== B) FAULT mid-frame swap (expect tear DETECTED → PASS neg) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$FAULT_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=1 -GPREP_SLOT_RECYCLE=1 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1 \
  -DDDR_FRAME_STORE_FAULT_MID_FRAME_SWAP \
  "${common_sv[@]}"
set +e
FAULT_OUT="$("$FAULT_BUILD/Vddr_frame_store_bank_swap_tear_tb" neg_fault 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
echo "fault rc=$FAULT_RC"

assert_sim_executed "bank-swap-product" "$GOOD_OUT" \
  "REAL_GEOM 720p24" "PASS pos_ontime" "PASS producer_late" \
  "PASS producer_never" "PASS neg_no_publish"
assert_sim_executed "bank-swap-fault" "$FAULT_OUT" \
  "PASS neg_midframe_fault" "non-tautological"

if [[ "$GOOD_RC" -ne 0 ]]; then
  echo "FAIL: product tear-free suite rc=$GOOD_RC" >&2
  exit 1
fi
if [[ "$FAULT_RC" -ne 0 ]]; then
  echo "FAIL: mid-frame FAULT twin did not detect tear rc=$FAULT_RC" >&2
  exit 1
fi
echo "OK ddr_frame_store_bank_swap_tear: product mono-bank + FAULT tear detected (TB executed)"
exit 0
