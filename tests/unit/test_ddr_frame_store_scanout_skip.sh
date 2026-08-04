#!/usr/bin/env bash
# Post-present scanout SKIP identity gate (w-geom).
# A) product holds=1: free-gated 24-in/60-out must PASS never_swapped=0;
#    overwrite-while-pending must REPRO_OK identity skip on same RTL.
# B) holds=0: collide path must REPRO_OK skip/freeze class (907e5950).
# TB must EXECUTE (not compile-only). PINNOTFOUND/%Error → rc=2 via run_verilator.
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

PRODUCT_BUILD="$ROOT/build/verilator/ddr_scanout_skip_product"
HOLDS0_BUILD="$ROOT/build/verilator/ddr_scanout_skip_holds0"
mkdir -p "$PRODUCT_BUILD" "$HOLDS0_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_scanout_skip_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_scanout_skip_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_scanout_skip_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== A) PRODUCT holds=1 sticky=1: free-gated PASS + overwrite REPRO ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$PRODUCT_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=1 -GPREP_SLOT_RECYCLE=1 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1 \
  "${common_sv[@]}"
set +e
PRODUCT_OUT="$(SKIP_TB_MODE=product "$PRODUCT_BUILD/Vddr_frame_store_scanout_skip_tb" 2>&1)"
PRODUCT_RC=$?
set -e
printf '%s\n' "$PRODUCT_OUT"
echo "product rc=$PRODUCT_RC"

echo "=== B) HOLDS0: collide must REPRO skip/freeze class ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$HOLDS0_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=1 -GPREP_SLOT_RECYCLE=1 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=0 \
  "${common_sv[@]}"
set +e
HOLDS0_OUT="$(SKIP_TB_MODE=holds0 "$HOLDS0_BUILD/Vddr_frame_store_scanout_skip_tb" 2>&1)"
HOLDS0_RC=$?
set -e
printf '%s\n' "$HOLDS0_OUT"
echo "holds0 rc=$HOLDS0_RC"

assert_sim_executed "skip-product" "$PRODUCT_OUT" \
  "PASS H1" "PASS pure identity" "PASS rtl_free_gated_24in60" "REPRO_OK rtl_overwrite_pending"
assert_sim_executed "skip-holds0" "$HOLDS0_OUT" \
  "PASS H1" "REPRO_OK rtl_holds0_collide"

if [[ "$PRODUCT_RC" -ne 0 ]]; then
  echo "FAIL: product skip TB rc=$PRODUCT_RC" >&2
  exit 1
fi
if [[ "$HOLDS0_RC" -ne 0 ]]; then
  echo "FAIL: holds0 skip TB rc=$HOLDS0_RC" >&2
  exit 1
fi
if ! grep -q 'PASS rtl_free_gated_24in60' <<<"$PRODUCT_OUT"; then
  echo "FAIL: free-gated product path did not PASS" >&2
  exit 1
fi
if ! grep -q 'REPRO_OK rtl_overwrite_pending' <<<"$PRODUCT_OUT"; then
  echo "FAIL: overwrite path did not REPRO skip" >&2
  exit 1
fi
if ! grep -q 'REPRO_OK rtl_holds0_collide' <<<"$HOLDS0_OUT"; then
  echo "FAIL: holds0 did not REPRO" >&2
  exit 1
fi
echo "OK ddr_frame_store_scanout_skip: free-gated PASS + overwrite REPRO + holds0 REPRO (TB executed)"
exit 0
