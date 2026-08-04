#!/usr/bin/env bash
# Real-RTL scanout shear / left-edge wander gate.
# After src_y_line fix: stride_fault stays RED; product_slow/fast must CLEAN.
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

BUILD="$ROOT/build/verilator/ddr_scanout_shear"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build --top-module ddr_frame_store_scanout_shear_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
  -CFLAGS "-std=c++17 -O2" \
  --Mdir "$BUILD" \
  "$ROOT/tests/rtl/ddr_frame_store_scanout_shear_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_frame_store_scanout_shear_tb.cpp"

set +e
OUT="$("$BUILD/Vddr_frame_store_scanout_shear_tb" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "shear_sim true rc=$RC"
assert_sim_executed "shear" "$OUT" \
  "REPRO_OK stride_fault" "PASS product_slow clean" "PASS product_fast clean" \
  "CASE stride_fault" "CASE product_slow" "CASE product_fast"

if [[ "$RC" -ne 0 ]] \
  || ! grep -q 'REPRO_OK stride_fault' <<<"$OUT" \
  || ! grep -q 'PASS product_slow clean' <<<"$OUT" \
  || ! grep -q 'PASS product_fast clean' <<<"$OUT"; then
  echo "FAIL ddr_frame_store_scanout_shear (need REPRO stride + CLEAN product_slow/fast)" >&2
  exit 1
fi
echo "OK ddr_frame_store_scanout_shear (TB executed)"
exit 0
