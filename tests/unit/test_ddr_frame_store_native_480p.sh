#!/usr/bin/env bash
# Native 480p DDR path gate (w-geom).
# A) Host publish ABI: 624x480 I420 accepted, plane offsets, capacity, no 320 clamp
# B) RTL scanout: full-height product geometry, plane bases, left edge @ PRESENT_X
# PINNOTFOUND / compile-only → rc=2 (not a pass). Soft-skip≠PASS.
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

echo "=== A) host publish ABI (624x480 I420, no 320 clamp) ===" >&2
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
assert_sim_executed "host-publish" "$HOST_OUT" "PASS test_native_480p_ddr_publish" "NO_320_CLAMP"

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
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_native_480p_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_native_480p_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
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

echo "OK ddr_frame_store_native_480p: host publish NO_320_CLAMP + RTL plane_bases + left_edge@PRESENT_X"
echo "ARM-ONLY for content ladder: product RBF already CODED 624x480 / FRAME 640x480."
exit 0
