#!/usr/bin/env bash
# RED-before-GREEN: fabric yuv_bt601_npx BT.601 YUV→RGB (PPC=2).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv"
TOP="$ROOT/tests/rtl/yuv_bt601_npx_tb_top.sv"
TB="$ROOT/tests/rtl/yuv_bt601_npx_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
BUILD_POS="$ROOT/build/verilator/yuv_bt601_npx_pos"
BUILD_NEG="$ROOT/build/verilator/yuv_bt601_npx_neg"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

build_one() {
  local mdir="$1"
  mkdir -p "$mdir"
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$mdir" \
    --top-module yuv_bt601_npx_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2" \
    "$RTL" "$TOP" "$TB"
}

echo "RTL SIM: yuv_bt601_npx using $VERILATOR_VERSION" >&2
build_one "$BUILD_POS"
EXE="$BUILD_POS/Vyuv_bt601_npx_tb_top"

# --- RED: UV swap must fail ---
set +e
OUT_NEG_UV="$(YUV_NEG_UV_SWAP=1 "$EXE" 2>&1)"
RC_NEG_UV=$?
set -e
printf '%s\n' "$OUT_NEG_UV"
echo "yuv_neg_uv_swap true rc=$RC_NEG_UV"
if [[ "$RC_NEG_UV" -eq 0 ]]; then
  echo "FAIL: UV-swap negative unexpectedly PASSed" >&2
  exit 1
fi
echo "RED proof: UV_SWAP failed as expected (rc=$RC_NEG_UV)" >&2

# --- RED: limited-range oracle must fail against full-range DUT ---
set +e
OUT_NEG_LIM="$(YUV_NEG_LIMITED=1 "$EXE" 2>&1)"
RC_NEG_LIM=$?
set -e
printf '%s\n' "$OUT_NEG_LIM"
echo "yuv_neg_limited true rc=$RC_NEG_LIM"
if [[ "$RC_NEG_LIM" -eq 0 ]]; then
  echo "FAIL: limited-range negative unexpectedly PASSed" >&2
  exit 1
fi
echo "RED proof: LIMITED failed as expected (rc=$RC_NEG_LIM)" >&2

# --- GREEN ---
# shellcheck source=tests/unit/lib_rtl_sim_gate.sh
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
set +e
OUT_POS="$("$EXE" 2>&1)"
RC_POS=$?
set -e
printf '%s\n' "$OUT_POS"
echo "yuv_bt601_npx_pos true rc=$RC_POS"
if [[ "$RC_POS" -ne 0 ]]; then
  exit "$RC_POS"
fi
assert_sim_executed "yuv_bt601_npx" "$OUT_POS" "YUV_BT601_NPX PASS"
echo "yuv_bt601_npx Verilator gate PASS"
