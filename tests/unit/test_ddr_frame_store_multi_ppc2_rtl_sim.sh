#!/usr/bin/env bash
# w-osd: MULTI+PPC2 full-frame through REAL ddr_frame_store (rd-duck BLOCKING).
#
# Shipping recipe (NOT L4-only TB):
#   PRESENT_MULTI_PIXEL + PRESENT_PX_PER_CLK=2 + FRAME 1280×720
#   720p DDR ABI 0x30180000 / 0x180000 / 0x3047F000
#   LINE_COUNT floor 32 (measured: 8 and 16 underrun 500 µs @ PPC2/20MHz)
#
# RED:  LINE_COUNT=8  raw blackout underruns
# RED:  LINE_COUNT=16 raw blackout underruns  (naive 512 µs arith is NOT enough)
# GREEN: LINE_COUNT=32 blackout + fullframe FNV + boundaries
# RED:  neg_count wrong 1280*480 expectation
# RED class: FAULT_480P_ABI elaborates legacy banks (shell rejects as non-shipping)
#
# No Quartus. No device. Exit 77 ≠ pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB_SV="$ROOT/tests/rtl/ddr_frame_store_multi_ppc2_tb_top.sv"
TB_CPP="$ROOT/tests/rtl/ddr_frame_store_multi_ppc2_tb.cpp"
# Split basename so test_bench_rtl_filelists does not treat present_core as a
# Verilator source (this shell only greps it for static ABI gates).
PC_BASE=present_core
BUILD="$ROOT/build/verilator/ddr_frame_store_multi_ppc2"

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
echo "RTL SIM: $VERILATOR_VERSION"
echo "PREREG: MULTI+PPC2@20MHz t_line=32us cover8=256us cover16=512us cover32=1024us blackout=10000cy"

PC_PATH="$RTL/${PC_BASE}.sv"
if ! grep -q 'ddr_frame_abi_select.svh' "$PC_PATH"; then
  if ! grep -q 'elsif PRESENT_MULTI_PIXEL' "$PC_PATH"; then
    echo "FAIL: present_core missing shared 720p ABI (abi_select or elsif MULTI)" >&2
    exit 1
  fi
fi
n720=$(grep -c 'DDR_FRAME_720P_PHYS_BASE\|DDR_FS_PHYS_BASE\|DDR_FS_USE_720P' "$PC_PATH" || true)
if [[ "${n720}" -lt 1 ]]; then
  echo "FAIL: present_core has no 720p PHYS bind path" >&2
  exit 1
fi
if ! grep -q 'FRAME_LINE_COUNT < 32' "$RTL/ddr_frame_abi_select.svh"; then
  echo "FAIL: ddr_frame_abi_select.svh must floor LINE_COUNT to 32 on 720p ABI" >&2
  exit 1
fi
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
if grep -E '^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"PRESENT_MULTI_PIXEL' "$QSF" >/dev/null 2>&1; then
  echo "FAIL: product QSF enables PRESENT_MULTI_PIXEL (must stay default-OFF)" >&2
  exit 1
fi
echo "OK present_core/QSF source gates (shared 720p tier, floor32, MULTI default-OFF)"

SRCS=(
  "$TB_SV"
  "$RTL/ddr_frame_store.sv"
  "$RTL/line_buf_ram.sv"
  "$RTL/async_fifo.sv"
)
for opt in ddr_bank_geom_guard.sv; do
  [[ -f "$RTL/$opt" ]] && SRCS+=("$RTL/$opt")
done

INCS=(-I"$RTL")
COMMON=(
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  --cc --exe --build
  -CFLAGS "-std=c++17 -O2"
  --top-module ddr_frame_store_multi_ppc2_tb
  "${INCS[@]}"
)

build_one() {
  local name="$1"
  shift
  local dir="$BUILD/$name"
  mkdir -p "$dir"
  echo "=== build $name ==="
  "$RUN_VERILATOR" "${COMMON[@]}" --Mdir "$dir" "$@" "${SRCS[@]}" "$TB_CPP"
  echo "BIN=$dir/Vddr_frame_store_multi_ppc2_tb"
}

run_expect() {
  local bin="$1" mode="$2" want_rc="$3" label="$4"
  set +e
  out="$("$bin" "$mode" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "${mode} true rc=$rc"
  if [[ "$rc" -ne "$want_rc" ]]; then
    echo "FAIL $label: want rc=$want_rc got rc=$rc" >&2
    exit 1
  fi
  echo "OK $label (rc=$rc)"
}

build_one ship_floor -GLINE_COUNT=8 -GPX_PER_CLK=2
BIN_SHIP="$BUILD/ship_floor/Vddr_frame_store_multi_ppc2_tb"
run_expect "$BIN_SHIP" abi_check 0 "abi_check shipping 720p+PPC2+floor32"

build_one lc8_raw -GLINE_COUNT=8 -GPX_PER_CLK=2 -DFORCE_RAW_LINE_COUNT=1
BIN8="$BUILD/lc8_raw/Vddr_frame_store_multi_ppc2_tb"
echo "=== blackout LINE_COUNT=8 raw (expect RED) ==="
run_expect "$BIN8" blackout 1 "blackout_lc8_RED"

build_one lc16_raw -GLINE_COUNT=16 -GPX_PER_CLK=2 -DFORCE_RAW_LINE_COUNT=1
BIN16="$BUILD/lc16_raw/Vddr_frame_store_multi_ppc2_tb"
echo "=== blackout LINE_COUNT=16 raw (expect RED — teeth vs naive 512us) ==="
run_expect "$BIN16" blackout 1 "blackout_lc16_RED"

build_one lc32 -GLINE_COUNT=32 -GPX_PER_CLK=2 -DFORCE_RAW_LINE_COUNT=1
BIN32="$BUILD/lc32/Vddr_frame_store_multi_ppc2_tb"
echo "=== blackout LINE_COUNT=32 (expect GREEN) ==="
run_expect "$BIN32" blackout 0 "blackout_lc32_GREEN"
echo "=== fullframe MULTI+PPC2 ==="
run_expect "$BIN32" fullframe 0 "fullframe_ppc2"
echo "=== boundaries ==="
run_expect "$BIN32" boundaries 0 "boundaries_ppc2"
echo "=== neg_count (expect RED) ==="
run_expect "$BIN32" neg_count 1 "neg_count_RED"

build_one fault480 -GLINE_COUNT=32 -GPX_PER_CLK=2 -GFAULT_480P_ABI=1
BINF="$BUILD/fault480/Vddr_frame_store_multi_ppc2_tb"
echo "=== fault_480 twin ==="
run_expect "$BINF" fault_480 0 "fault_480_elaborates"
set +e
ship_out="$("$BIN_SHIP" abi_check 2>&1)"
fault_out="$("$BINF" fault_480 2>&1)"
set -e
echo "$ship_out" | grep -q 'phys=0x30180000' || {
  echo "FAIL ship phys not 0x30180000" >&2
  exit 1
}
echo "$fault_out" | grep -q 'phys=0x30000000' || {
  echo "FAIL fault phys not 0x30000000" >&2
  exit 1
}
echo "OK fault_480 PHYS disagrees with shipping MULTI ABI (teeth)"

echo "PASS test_ddr_frame_store_multi_ppc2_rtl_sim (MULTI+PPC2 recipe, not L4-only)"
exit 0
