#!/usr/bin/env bash
# Full-pixel Option-C 720p READ proof (w-scaler).
# GREEN: full_grey, full_chroma, bank_swap
# RED:   wrong_stride, half_chroma (must stay dirty)
# Soft-skip≠PASS. true rc captured directly (never through a pipe).
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

BUILD="$ROOT/build/verilator/ddr_720p_pixel"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_720p_pixel_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_720p_pixel_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_720p_pixel_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD 720p full-pixel TB ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD" "${common_sv[@]}"

run_case() {
  local name="$1"
  local expect_pass="$2" # 1=green must rc0; 0=red twin handled inside binary
  set +e
  local out rc
  out="$(PIXEL_CASE="$name" "$BUILD/Vddr_frame_store_720p_pixel_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "${name}_true_rc=$rc"
  if [[ "$expect_pass" -eq 1 ]]; then
    assert_sim_executed "720p-$name" "$out" "EXECUTED" "PASS"
    if [[ "$rc" -ne 0 ]]; then
      echo "FAIL $name: expected green true rc=0 got $rc" >&2
      exit 1
    fi
  else
    assert_sim_executed "720p-$name" "$out" "EXECUTED" "PASS red-check"
    if [[ "$rc" -ne 0 ]]; then
      echo "FAIL $name: red-check binary true rc=$rc (discriminator lost power?)" >&2
      exit 1
    fi
  fi
}

echo "=== GREEN full_grey (every pixel Y→RGB) ===" >&2
run_case full_grey 1

echo "=== GREEN full_chroma (BT.601 unique U/V) ===" >&2
run_case full_chroma 1

echo "=== GREEN bank_swap (no tear while bank1 poisoned) ===" >&2
run_case bank_swap 1

echo "=== RED wrong_stride (pack 1296 vs geom 1280) ===" >&2
run_case wrong_stride 0

echo "=== RED half_chroma (U plane +1 line) ===" >&2
run_case half_chroma 0

echo "OK ddr_720p_pixel: full_grey + full_chroma + bank_swap GREEN; wrong_stride + half_chroma RED"
exit 0
