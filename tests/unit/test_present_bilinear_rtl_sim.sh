#!/usr/bin/env bash
# PRESENT_WINDOW_BILINEAR red-before-green gate.
# Product path leaves macro OFF (NN). This builds WITH the macro and proves
# lerp mixes; nn_equiv at edge; neg fails if stuck at p00.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: missing marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
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
  exit "$VERILATOR_RC"
fi

echo "RTL SIM: using $VERILATOR_VERSION" >&2
BUILD="$ROOT/build/verilator/present_bilinear"
mkdir -p "$BUILD"

common_sv=(
  "$ROOT/tests/rtl/present_bilinear_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_content_window.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_bilinear_lerp.sv"
  "$ROOT/tests/rtl/present_bilinear_tb.cpp"
)
vflags=(--cc --exe --build --top-module present_bilinear_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2"
  +define+PRESENT_WINDOW_BILINEAR)

echo "=== BUILD present_bilinear (macro ON) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD" "${common_sv[@]}"

run_mode() {
  local mode="$1"
  set +e
  local out rc
  out="$(BILINEAR_MODE="$mode" "$BUILD/Vpresent_bilinear_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "${mode} true rc=$rc"
  eval "${mode}_OUT=$(printf '%q' "$out")"
  eval "${mode}_RC=$rc"
}

echo "=== A) nn_equiv edge ===" >&2
run_mode nn_equiv
echo "=== B) mid_lerp ===" >&2
run_mode mid_lerp
echo "=== C) product540 960x540 ship path ===" >&2
run_mode product540
echo "=== D) neg_nn_only ===" >&2
run_mode neg_nn_only

assert_sim_executed nn_equiv "$nn_equiv_OUT" "CASE nn_equiv EXECUTED" "PASS bilinear nn_equiv"
assert_sim_executed mid_lerp "$mid_lerp_OUT" "CASE mid_lerp EXECUTED" "PASS bilinear mid_lerp"
assert_sim_executed product540 "$product540_OUT" "CASE product540_bil EXECUTED" "PASS bilinear product540"
assert_sim_executed neg_nn_only "$neg_nn_only_OUT" "CASE neg_nn_only EXECUTED" "PASS neg_nn_only"

if [[ "$nn_equiv_RC" -ne 0 || "$mid_lerp_RC" -ne 0 || "$product540_RC" -ne 0 || "$neg_nn_only_RC" -ne 0 ]]; then
  echo "FAIL bilinear modes" >&2
  exit 1
fi

echo "OK present_bilinear_rtl_sim: nn_equiv + mid_lerp + product540 + neg_nn_only (macro ON)"
exit 0
