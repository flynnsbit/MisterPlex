#!/usr/bin/env bash
# Full 1280x720 real ddr_frame_store @ PPC2 + clk 20:90 + stalls (w-osd).
# rd-duck: PARTIAL_CLOSED_READER only — beat counts are refill-demand (scalar-
# identical). Dual-lane odd/even checksum is the PPC2 correctness tooth.
# SCALAR_VIEW_NEG must RED while payload shape stays comparable.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed rc=$VERILATOR_RC" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/ddr_frame_store_720p_ppc2_bus"
rm -rf "$BUILD"
mkdir -p "$BUILD/lc32" "$BUILD/lc8" "$BUILD/scalar_neg"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
echo "PRE-REG: LC32 GREEN PARTIAL_CLOSED_READER; SCALAR_VIEW_NEG RED; LC8 RED; G2 RED"
echo "PRE-REG: fabric_bw_closed=false; ppc2_reader_closed=false"

build_one() {
  local dir="$1" lc="$2" cflags="$3"
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$dir" \
    --top-module ddr_frame_store_720p_ppc2_bus_tb \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
    -CFLAGS "$cflags" \
    -GLINE_COUNT="$lc" \
    +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
    "$ROOT/tests/rtl/ddr_frame_store_720p_ppc2_bus_tb_top.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
    "$ROOT/tests/rtl/ddr_frame_store_720p_ppc2_bus_tb.cpp"
}

echo "=== LC=32 PPC2 dual-lane (expect GREEN PARTIAL_CLOSED_READER) ==="
build_one "$BUILD/lc32" 32 "-std=c++17 -O2"
set +e
OUT32="$("$BUILD/lc32/Vddr_frame_store_720p_ppc2_bus_tb" 2>&1)"
RC32=$?
set -e
printf '%s\n' "$OUT32"
echo "lc32 true rc=$RC32"
[[ "$RC32" -eq 0 ]] || { echo "FAIL LC32" >&2; exit 1; }
echo "$OUT32" | grep -q 'G2_hang_mutant' || { echo "FAIL missing G2" >&2; exit 1; }
echo "$OUT32" | grep -q 'payload_formula=172800+LC\*240' || { echo "FAIL missing tight formula" >&2; exit 1; }
echo "$OUT32" | grep -q 'PARTIAL_CLOSED_READER' || { echo "FAIL must claim PARTIAL_CLOSED_READER only" >&2; exit 1; }
echo "$OUT32" | grep -q 'fabric_bw_closed=false' || { echo "FAIL fabric_bw_closed must be false" >&2; exit 1; }
echo "$OUT32" | grep -q 'ppc2_reader_closed=false' || { echo "FAIL ppc2_reader_closed must be false" >&2; exit 1; }
echo "$OUT32" | grep -q 'NOT fit-release CLOSED' || { echo "FAIL must not claim fit CLOSED" >&2; exit 1; }
echo "$OUT32" | grep -q 'isolated_reader_stress' || { echo "FAIL missing stress class label" >&2; exit 1; }
echo "$OUT32" | grep -q 'dual_dist=' || { echo "FAIL missing dual-lane checksum" >&2; exit 1; }
echo "$OUT32" | grep -q 'fnv_want=' || { echo "FAIL missing full-frame FNV want" >&2; exit 1; }
G0_PAY=$(echo "$OUT32" | sed -n 's/.*G0_full_ideal EXECUTED payload=\([0-9]*\).*/\1/p' | head -1)
[[ -n "$G0_PAY" ]] || { echo "FAIL parse G0 payload" >&2; exit 1; }
echo "OK LC32 G0 payload=$G0_PAY PARTIAL_CLOSED_READER"

echo "=== SCALAR_VIEW_NEG (expect RED dual-lane; payload shape comparable) ==="
build_one "$BUILD/scalar_neg" 32 "-std=c++17 -O2 -DSCALAR_VIEW_NEG=1"
set +e
OUTS="$("$BUILD/scalar_neg/Vddr_frame_store_720p_ppc2_bus_tb" 2>&1)"
RCS=$?
set -e
printf '%s\n' "$OUTS"
echo "scalar_neg true rc=$RCS"
[[ "$RCS" -ne 0 ]] || { echo "FAIL SCALAR_VIEW_NEG must RED (dual-lane tooth broken)" >&2; exit 1; }
echo "$OUTS" | grep -Eq 'dual_lane|FNV|SCALAR_VIEW_NEG' \
  || { echo "FAIL SCALAR_VIEW_NEG did not hit dual/FNV tooth" >&2; exit 1; }
G0S=$(echo "$OUTS" | sed -n 's/.*G0_full_ideal EXECUTED payload=\([0-9]*\).*/\1/p' | head -1)
if [[ -n "$G0S" ]]; then
  [[ "$G0S" == "$G0_PAY" ]] || {
    echo "FAIL scalar G0 payload=$G0S != ppc2 $G0_PAY (expected refill-identical)" >&2
    exit 1
  }
  echo "OK SCALAR_VIEW_NEG RED with G0 payload=$G0S identical to PPC2 (refill-only)"
else
  echo "OK SCALAR_VIEW_NEG RED (failed before/at G0 dual check; payload parse optional)"
fi

echo "=== LC=8 teeth (expect RED) ==="
build_one "$BUILD/lc8" 8 "-std=c++17 -O2"
set +e
OUT8="$("$BUILD/lc8/Vddr_frame_store_720p_ppc2_bus_tb" 2>&1)"
RC8=$?
set -e
printf '%s\n' "$OUT8"
echo "lc8 true rc=$RC8"
[[ "$RC8" -ne 0 ]] || { echo "FAIL LC8 should RED" >&2; exit 1; }
echo "OK LC8 RED rc=$RC8"
echo "PASS test_ddr_frame_store_720p_ppc2_bus PARTIAL_CLOSED_READER (fit blocker remains; fabric_bw_closed=false)"
exit 0
