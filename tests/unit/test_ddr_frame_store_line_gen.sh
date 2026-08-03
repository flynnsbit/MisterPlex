#!/usr/bin/env bash
# Line-cache frame-gen gate (rd-duck stale top-row on bank0→1→0).
# A) LINE_CACHE_FRAME_GEN=0 → REPRO_OK stale frame3 top == frame1
# B) LINE_CACHE_FRAME_GEN=1 → PASS fresh frame3 top + geom gen bump
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

BROKEN_BUILD="$ROOT/build/verilator/ddr_line_gen_broken"
GOOD_BUILD="$ROOT/build/verilator/ddr_line_gen_good"
mkdir -p "$BROKEN_BUILD" "$GOOD_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_line_gen_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_line_gen_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_line_gen_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== A) BROKEN: LINE_CACHE_FRAME_GEN=0 (expect REPRO stale top) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BROKEN_BUILD" \
  -GLINE_CACHE_FRAME_GEN=0 \
  "${common_sv[@]}"
set +e
BROKEN_OUT="$(LINE_GEN_EXPECT_FRESH=0 "$BROKEN_BUILD/Vddr_frame_store_line_gen_tb" 2>&1)"
BROKEN_RC=$?
set -e
printf '%s\n' "$BROKEN_OUT"
echo "broken rc=$BROKEN_RC"

echo "=== B) GOOD: LINE_CACHE_FRAME_GEN=1 (expect PASS fresh top) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  -GLINE_CACHE_FRAME_GEN=1 \
  "${common_sv[@]}"
set +e
GOOD_OUT="$(LINE_GEN_EXPECT_FRESH=1 "$GOOD_BUILD/Vddr_frame_store_line_gen_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "good rc=$GOOD_RC"

assert_sim_executed "line-gen-broken" "$BROKEN_OUT" "REPRO_OK line_gen_fault" "PRE-REGISTER"
assert_sim_executed "line-gen-good" "$GOOD_OUT" "PASS line_gen_product" "PRE-REGISTER"

if [[ "$BROKEN_RC" -ne 0 ]] || ! grep -q 'REPRO_OK line_gen_fault' <<<"$BROKEN_OUT"; then
  echo "FAIL: LINE_CACHE_FRAME_GEN=0 did not reproduce stale top-row" >&2
  exit 1
fi
if [[ "$GOOD_RC" -ne 0 ]] || ! grep -q 'PASS line_gen_product' <<<"$GOOD_OUT"; then
  echo "FAIL: LINE_CACHE_FRAME_GEN=1 did not keep frame3 top fresh" >&2
  exit 1
fi
echo "OK ddr_frame_store_line_gen: REPRO_OK fault + PASS product (TB executed)"
exit 0
