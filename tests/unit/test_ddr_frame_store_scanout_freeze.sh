#!/usr/bin/env bash
# Real-RTL scanout freeze gate (9eb1431a class).
# A) src_y_line + legacy clear-on-current-sched → must REPRO freeze
# B) src_y_line + sticky pending_ready on prep → must PASS motion + swaps
# No WANT_Y_FORCE_TOP.
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
    echo "FAIL $label: compile-only or empty run is not a pass (soft-skip≠PASS)" >&2
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

BROKEN_BUILD="$ROOT/build/verilator/ddr_scanout_freeze_broken"
GOOD_BUILD="$ROOT/build/verilator/ddr_scanout_freeze_good"
mkdir -p "$BROKEN_BUILD" "$GOOD_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_scanout_freeze_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_scanout_freeze_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_scanout_freeze_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -I"$ROOT/fpga/Plex_MiSTer/rtl"
  -CFLAGS "-std=c++17 -O2")

echo "=== A) BROKEN: src_y_line + sticky=0 recycle=0 (expect REPRO_OK freeze / 9eb1431a) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BROKEN_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=0 -GPREP_SLOT_RECYCLE=0 \
  "${common_sv[@]}"
set +e
BROKEN_OUT="$("$BROKEN_BUILD/Vddr_frame_store_scanout_freeze_tb" 2>&1)"
BROKEN_RC=$?
set -e
printf '%s\n' "$BROKEN_OUT"
echo "broken rc=$BROKEN_RC"

echo "=== B) GOOD: src_y_line + sticky=1 recycle=1 (expect PASS motion) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=1 -GPREP_SLOT_RECYCLE=1 \
  "${common_sv[@]}"
set +e
GOOD_OUT="$("$GOOD_BUILD/Vddr_frame_store_scanout_freeze_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "good rc=$GOOD_RC"

assert_sim_executed "freeze-broken" "$BROKEN_OUT"   "REPRO_OK" "src_y_line_9eb1431a" "freeze=1" "build: LINE_ONLY"
assert_sim_executed "freeze-good" "$GOOD_OUT"   "PASS" "src_y_line_product_fix" "motion=1" "build: LINE_ONLY"

if [[ "$BROKEN_RC" -ne 0 ]] || ! grep -q 'REPRO_OK' <<<"$BROKEN_OUT"; then
  echo "FAIL: broken config did not reproduce freeze-class" >&2
  exit 1
fi
if [[ "$GOOD_RC" -ne 0 ]] || ! grep -q 'PASS src_y_line_product_fix' <<<"$GOOD_OUT"; then
  echo "FAIL: good sticky+recycle product fix did not pass with executed TB" >&2
  exit 1
fi
echo "OK ddr_frame_store_scanout_freeze: REPRO_OK broken + PASS good (TB executed)"
exit 0
