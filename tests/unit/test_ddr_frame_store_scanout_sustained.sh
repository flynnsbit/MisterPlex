#!/usr/bin/env bash
# Sustained high-rate DDR scanout freeze gate (playback-class publish pressure).
# A) holds=0 → must REPRO freeze / lost swaps under collide presents
# B) holds=1 sticky=1 recycle=1 → must PASS motion across hundreds of frames
# Asserts TB EXECUTED (not compile-only). PINNOTFOUND/%Error → rc=2 via run_verilator.
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

BROKEN_BUILD="$ROOT/build/verilator/ddr_scanout_sustained_broken"
GOOD_BUILD="$ROOT/build/verilator/ddr_scanout_sustained_good"
mkdir -p "$BROKEN_BUILD" "$GOOD_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_scanout_sustained_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_scanout_sustained_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_scanout_sustained_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== A) BROKEN: sticky=0 recycle=0 holds=0 under sustained high-rate (expect REPRO freeze) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BROKEN_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=0 -GPREP_SLOT_RECYCLE=0 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=0 \
  "${common_sv[@]}"
set +e
BROKEN_OUT="$("$BROKEN_BUILD/Vddr_frame_store_scanout_sustained_tb" 2>&1)"
BROKEN_RC=$?
set -e
printf '%s\n' "$BROKEN_OUT"
echo "broken rc=$BROKEN_RC"

echo "=== B) GOOD: sticky=1 recycle=1 holds=1 sustained playback rate (expect PASS) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=1 -GPREP_SLOT_RECYCLE=1 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1 \
  "${common_sv[@]}"
set +e
GOOD_OUT="$("$GOOD_BUILD/Vddr_frame_store_scanout_sustained_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "good rc=$GOOD_RC"

assert_sim_executed "sustained-broken" "$BROKEN_OUT" \
  "PASS race model" "REPRO_OK" "sustained_nosticky" "freeze=1"
assert_sim_executed "sustained-good" "$GOOD_OUT" \
  "PASS race model" "PASS sustained_product" "motion=1" "build: holds=1"

if [[ "$BROKEN_RC" -ne 0 ]] || ! grep -q 'REPRO_OK sustained_nosticky' <<<"$BROKEN_OUT"; then
  echo "FAIL: sticky=0 under sustained high-rate did not reproduce freeze-class" >&2
  exit 1
fi
if [[ "$GOOD_RC" -ne 0 ]] || ! grep -q 'PASS sustained_product' <<<"$GOOD_OUT"; then
  echo "FAIL: product sticky+holds did not sustain motion under high-rate publish" >&2
  exit 1
fi
echo "OK ddr_frame_store_scanout_sustained: REPRO_OK nosticky + PASS product (TB executed)"
exit 0
