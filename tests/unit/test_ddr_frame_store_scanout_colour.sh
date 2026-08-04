#!/usr/bin/env bash
# Product-geometry colour / stripe gate (c5382bee class).
# A) chroma_zero pack → REPRO green_cast (silicon mean~72 fingerprint)
# B) product_uv pack  → PASS CLEAN (neutral greyscale + blue probe)
# C) stride640 pack   → REPRO dirty (discriminator stays live)
# PINNOTFOUND / compile-only → rc=2 (not a pass).
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

BUILD="$ROOT/build/verilator/ddr_scanout_colour"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_scanout_colour_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_scanout_colour_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_scanout_colour_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl"
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD product geometry colour TB (CODED_W=624) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD" "${common_sv[@]}"

echo "=== A) chroma_zero (expect REPRO_OK green_cast / c5382bee class) ===" >&2
set +e
ZERO_OUT="$(COLOUR_CASE=chroma_zero "$BUILD/Vddr_frame_store_scanout_colour_tb" 2>&1)"
ZERO_RC=$?
set -e
printf '%s\n' "$ZERO_OUT"
echo "chroma_zero rc=$ZERO_RC"

echo "=== B) product_uv (expect PASS CLEAN on c5382bee RTL) ===" >&2
set +e
PROD_OUT="$(COLOUR_CASE=product_uv "$BUILD/Vddr_frame_store_scanout_colour_tb" 2>&1)"
PROD_RC=$?
set -e
printf '%s\n' "$PROD_OUT"
echo "product_uv rc=$PROD_RC"

echo "=== C) stride640 (expect REPRO_OK dirty discriminator) ===" >&2
set +e
STRIDE_OUT="$(COLOUR_CASE=stride640 "$BUILD/Vddr_frame_store_scanout_colour_tb" 2>&1)"
STRIDE_RC=$?
set -e
printf '%s\n' "$STRIDE_OUT"
echo "stride640 rc=$STRIDE_RC"

echo "=== D) bars_zero (1px Y bars + U=V=0 → green_cast + high stripe) ===" >&2
set +e
BARS0_OUT="$(COLOUR_CASE=bars_zero "$BUILD/Vddr_frame_store_scanout_colour_tb" 2>&1)"
BARS0_RC=$?
set -e
printf '%s\n' "$BARS0_OUT"
echo "bars_zero rc=$BARS0_RC"

echo "=== E) bars_uv (1px Y bars + U=V=128 → greyscale stripe, no green_cast) ===" >&2
set +e
BARSUV_OUT="$(COLOUR_CASE=bars_uv "$BUILD/Vddr_frame_store_scanout_colour_tb" 2>&1)"
BARSUV_RC=$?
set -e
printf '%s\n' "$BARSUV_OUT"
echo "bars_uv rc=$BARSUV_RC"

assert_sim_executed "colour-chroma_zero" "$ZERO_OUT" "REPRO_OK" "chroma_zero" "EXECUTED" "green_cast=1"
assert_sim_executed "colour-product_uv" "$PROD_OUT" "PASS product_uv" "EXECUTED" "green_cast=0"
assert_sim_executed "colour-stride640" "$STRIDE_OUT" "REPRO_OK" "stride640" "EXECUTED"
assert_sim_executed "colour-bars_zero" "$BARS0_OUT" "REPRO_OK" "bars_zero" "EXECUTED" "green_cast=1"
assert_sim_executed "colour-bars_uv" "$BARSUV_OUT" "PASS bars_uv" "EXECUTED" "green_cast=0"

if [[ "$ZERO_RC" -ne 0 ]]; then
  echo "FAIL: chroma_zero did not reproduce green_cast class" >&2
  exit 1
fi
if [[ "$PROD_RC" -ne 0 ]]; then
  echo "FAIL: product_uv not CLEAN on fitted-class RTL — colour bug is in scanout path" >&2
  exit 1
fi
if [[ "$STRIDE_RC" -ne 0 ]]; then
  echo "FAIL: stride640 discriminator lost power" >&2
  exit 1
fi
if [[ "$BARS0_RC" -ne 0 ]]; then
  echo "FAIL: bars_zero did not REPRO green+stripe class" >&2
  exit 1
fi
if [[ "$BARSUV_RC" -ne 0 ]]; then
  echo "FAIL: bars_uv not CLEAN greyscale stripes on product RTL" >&2
  exit 1
fi

echo "OK ddr_frame_store_scanout_colour: REPRO chroma_zero/bars_zero + PASS product_uv/bars_uv + REPRO stride640 (TB executed)"
echo "NOTE: product_uv PASS ⇒ c5382bee RTL YUV matrix/scanout CLEAN under correct I420."
echo "      silicon green_cast mean~72 matches chroma_zero (U=V=0), not a matrix bug."
echo "      bars_zero shows 1px Y structure under dead chroma can look like green striping."
exit 0
