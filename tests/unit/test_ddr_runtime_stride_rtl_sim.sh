#!/usr/bin/env bash
# ddr_frame_store runtime stride / CODED geometry — red-before-green Verilator gate.
# A) geom_enable=0 → legacy 624 plane bases REPRO
# B) geom_enable=1 1280×720 stride=1280 → U/V bases 115200/144000 PASS
# C) neg: geom=0 cannot satisfy 720p bases PASS (structural + live)
# D) red twin FAULT_IGNORE_GEOM → rt720 expectations FAIL
# Soft-skip≠PASS. true rc direct.
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
fi
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator --version failed rc=$VERILATOR_RC" >&2
  exit 3
fi

BUILD_G="$ROOT/build/verilator/ddr_runtime_stride_green"
BUILD_R="$ROOT/build/verilator/ddr_runtime_stride_red"
mkdir -p "$BUILD_G" "$BUILD_R"

COMMON=(
  -cc --exe --build -j 4
  --top-module ddr_frame_store_runtime_stride_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  "$ROOT/tests/rtl/ddr_frame_store_runtime_stride_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/tests/rtl/ddr_frame_store_runtime_stride_tb.cpp"
)

echo "=== GREEN build+run runtime stride ==="
set +e
"$RUN_VERILATOR" "${COMMON[@]}" -Mdir "$BUILD_G" >"$BUILD_G/build.log" 2>&1
BRC=$?
set -e
if [[ "$BRC" -ne 0 ]]; then
  tail -40 "$BUILD_G/build.log" >&2
  echo "FAIL green build true rc=$BRC" >&2
  exit "$BRC"
fi
set +e
GOUT="$("$BUILD_G/Vddr_frame_store_runtime_stride_tb" 2>&1)"
GRC=$?
set -e
echo "$GOUT"
assert_sim_executed "green" "$GOUT" \
  "CASE legacy624 EXECUTED" \
  "CASE rt720 EXECUTED" \
  "CASE neg_geom0_expect720 EXECUTED" \
  "PASS legacy624" \
  "PASS rt720" \
  "Option-C bank map" \
  "PASS red-check neg_geom0_expect720" \
  "RUNTIME_STRIDE_GREEN_DONE"
if [[ "$GRC" -ne 0 ]]; then
  echo "FAIL green runtime stride true rc=$GRC" >&2
  exit "$GRC"
fi
echo "OK green runtime stride true rc=0"

echo "=== RED twin FAULT_IGNORE_GEOM ==="
set +e
"$RUN_VERILATOR" "${COMMON[@]}" -Mdir "$BUILD_R" \
  +define+DDR_FRAME_STORE_FAULT_IGNORE_GEOM \
  -CFLAGS "-DDDR_FRAME_STORE_FAULT_IGNORE_GEOM" >"$BUILD_R/build.log" 2>&1
RBRC=$?
set -e
if [[ "$RBRC" -ne 0 ]]; then
  tail -40 "$BUILD_R/build.log" >&2
  echo "FAIL red build true rc=$RBRC" >&2
  exit "$RBRC"
fi
set +e
ROUT="$("$BUILD_R/Vddr_frame_store_runtime_stride_tb" --red-only 2>&1)"
RRC=$?
set -e
echo "$ROUT"
assert_sim_executed "red" "$ROUT" \
  "CASE rt720_against_ignore_geom EXECUTED" \
  "PASS red-check" \
  "RUNTIME_STRIDE_RED_DONE"
if [[ "$RRC" -ne 0 ]]; then
  echo "FAIL red-check true rc=$RRC (expected 0 = correctly detected miss)" >&2
  exit "$RRC"
fi
echo "OK red twin ignore-geom true rc=0"

echo "=== RED twin FAULT_FORCE_LEGACY_BANK_MAP ==="
BUILD_R2="$ROOT/build/verilator/ddr_runtime_stride_red_bank"
mkdir -p "$BUILD_R2"
set +e
"$RUN_VERILATOR" "${COMMON[@]}" -Mdir "$BUILD_R2" \
  +define+DDR_FRAME_STORE_FAULT_FORCE_LEGACY_BANK_MAP >"$BUILD_R2/build.log" 2>&1
R2BRC=$?
set -e
if [[ "$R2BRC" -ne 0 ]]; then
  tail -40 "$BUILD_R2/build.log" >&2
  echo "FAIL red-bank build true rc=$R2BRC" >&2
  exit "$R2BRC"
fi
set +e
R2OUT="$("$BUILD_R2/Vddr_frame_store_runtime_stride_tb" 2>&1)"
R2RC=$?
set -e
echo "$R2OUT"
if grep -q "PASS rt720 Option-C bank map" <<<"$R2OUT"; then
  echo "FAIL red-bank: Option-C Y matched under FORCE_LEGACY_BANK_MAP" >&2
  exit 1
fi
if [[ "$R2RC" -eq 0 ]]; then
  echo "FAIL red-bank: expected rt720 Option-C check to fail true rc=$R2RC" >&2
  exit 1
fi
echo "OK red twin FORCE_LEGACY_BANK_MAP true rc=$R2RC (expected non-zero)"

echo "PASS test_ddr_runtime_stride_rtl_sim all gates"
exit 0
