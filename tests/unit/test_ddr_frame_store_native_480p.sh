#!/usr/bin/env bash
# Native 480p DDR path gate (w-geom / w-nostub-720p).
# A) Host publish ABI: product 1280×720 canvas + legacy480 helper (test_native_480p_ddr_publish)
# B) RTL scanout: full-height lab 480p geometry, plane bases, left edge @ PRESENT_X
# PINNOTFOUND / compile-only → rc=2 (not a pass). Soft-skip≠PASS.
# Host markers must match tests/unit/test_native_480p_ddr_publish.cpp PASS line exactly
# (post Wave-1 product canvas: legacy480_ok, not historical NO_320_CLAMP).
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
CXX="${CXX:-g++}"
CXXFLAGS="-std=c++17 -O2 -Wall -Wextra -I$ROOT/host -I$ROOT/arm/misterplexd"

echo "=== A) host publish ABI (product 1280x720 + legacy480_ok) ===" >&2
mkdir -p "$ROOT/build"
"$CXX" $CXXFLAGS -o "$ROOT/build/test_native_480p_ddr_publish" \
  "$ROOT/tests/unit/test_native_480p_ddr_publish.cpp"
set +e
HOST_OUT="$("$ROOT/build/test_native_480p_ddr_publish" 2>&1)"
HOST_RC=$?
set -e
printf '%s\n' "$HOST_OUT"
echo "host_publish rc=$HOST_RC"
if [[ "$HOST_RC" -ne 0 ]]; then
  echo "FAIL native_480p host publish ABI" >&2
  exit 1
fi
# Dual markers from cpp PASS printf — red if binary empty/compile-only or marker drift.
assert_sim_executed "host-publish" "$HOST_OUT" \
  "PASS test_native_480p_ddr_publish" \
  "legacy480_ok" \
  "product_frame="

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found (host publish PASS)" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/ddr_native_480p"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_native_480p_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/mplex_hold_lcell.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_native_480p_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_native_480p_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -I"$ROOT/fpga/Plex_MiSTer/rtl"
  -CFLAGS "-std=c++17 -O2")

echo "=== B) BUILD + RUN full-height native 480p scanout TB ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD" "${common_sv[@]}"

set +e
RTL_OUT="$("$BUILD/Vddr_frame_store_native_480p_tb" 2>&1)"
RTL_RC=$?
set -e
printf '%s\n' "$RTL_OUT"
echo "native_480p_rtl rc=$RTL_RC"

assert_sim_executed "native-480p-rtl" "$RTL_OUT" "CASE native_480p EXECUTED" "PASS native_480p"

if [[ "$RTL_RC" -ne 0 ]]; then
  echo "FAIL: native 480p RTL scanout gate" >&2
  exit 1
fi

echo "OK ddr_frame_store_native_480p: host publish product_frame+legacy480_ok + RTL plane_bases + left_edge@PRESENT_X"
echo "LAB-ONLY 480p content-ladder helper (kPlex480p* / plex480pDdrFrameGeometry)."
echo "Product RBF is CODED 1280x720 / FRAME 1280x720 identity — not 624x480 / 640x480."
exit 0
