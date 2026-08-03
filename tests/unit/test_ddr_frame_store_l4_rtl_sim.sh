#!/usr/bin/env bash
# L4 720p ddr_frame_store reader gates:
#  1) blackout LINE_COUNT=8  → must RED  (underrun under 500us model)
#  2) blackout LINE_COUNT=16 → must GREEN (no underrun)
#  3) fullframe LINE_COUNT=16 → complete 1280x720 scan, last pixel matches layout
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
INC="-I$RTL"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing SKIP-as-pass" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
if grep -E '^[^#]*PLEX_PRESENT_720P_L4=1' "$QSF" >/dev/null; then
  echo "RTL SIM ERROR: PLEX_PRESENT_720P_L4 active in product QSF" >&2
  exit 2
fi
# FRAME_LINES_16 must be available in the L4 recipe (commented) and not force product.
if ! grep -E 'FRAME_LINES_16' "$QSF" >/dev/null; then
  echo "RTL SIM ERROR: Plex.qsf missing FRAME_LINES_16 L4 recipe entry" >&2
  exit 2
fi
if grep -E '^[^#]*FRAME_LINES_16=1' "$QSF" >/dev/null; then
  echo "RTL SIM ERROR: FRAME_LINES_16 active in product QSF (must stay default-off)" >&2
  exit 2
fi
if ! grep -E '^[^#]*FRAME_LINES_8=1' "$QSF" >/dev/null; then
  echo "RTL SIM ERROR: product default FRAME_LINES_8 missing" >&2
  exit 2
fi

echo "RTL SIM: using $VERILATOR_VERSION" >&2

build_one() {
  local lc="$1"
  local dir="$ROOT/build/verilator/ddr_frame_store_l4_lc${lc}"
  local bin="$dir/Vddr_frame_store_l4_tb"
  mkdir -p "$dir"
  "$RUN_VERILATOR" --cc --exe --build --Mdir "$dir" \
    --top-module ddr_frame_store_l4_tb -Wno-fatal \
    -GLINE_COUNT="${lc}" \
    $INC \
    -CFLAGS "-std=c++17 -O2" \
    "$ROOT/tests/rtl/ddr_frame_store_l4_tb_top.sv" \
    "$RTL/ddr_frame_store.sv" \
    "$RTL/line_buf_ram.sv" \
    "$RTL/async_fifo.sv" \
    "$ROOT/tests/rtl/ddr_frame_store_l4_tb.cpp" >&2
  if [[ ! -x "$bin" ]]; then
    echo "RTL SIM ERROR: missing binary $bin" >&2
    exit 2
  fi
  printf '%s\n' "$bin"
}

echo "=== build LINE_COUNT=8 ==="
BIN8="$(build_one 8)"
echo "BIN8=$BIN8"
echo "=== build LINE_COUNT=16 ==="
BIN16="$(build_one 16)"
echo "BIN16=$BIN16"

echo "=== blackout LINE_COUNT=8 (expect RED / underrun) ==="
set +e
OUT8="$("$BIN8" blackout 2>&1)"
RC8=$?
set -e
printf '%s\n' "$OUT8"
echo "blackout_lc8 true rc=$RC8"
if [[ "$RC8" -eq 0 ]]; then
  echo "RTL SIM ERROR: LINE_COUNT=8 blackout was GREEN — buffer too small must underrun" >&2
  exit 2
fi
if ! grep -q "FAIL blackout: line buffer underran" <<<"$OUT8"; then
  echo "RTL SIM ERROR: LINE_COUNT=8 did not report underrun FAIL marker" >&2
  exit 2
fi
echo "OK red-check: LINE_COUNT=8 underruns under 500us blackout (rc=$RC8)"

echo "=== blackout LINE_COUNT=16 (expect GREEN) ==="
set +e
OUT16="$("$BIN16" blackout 2>&1)"
RC16=$?
set -e
printf '%s\n' "$OUT16"
echo "blackout_lc16 true rc=$RC16"
if [[ "$RC16" -ne 0 ]]; then
  echo "RTL SIM ERROR: LINE_COUNT=16 blackout failed" >&2
  exit "$RC16"
fi
if ! grep -q "PASS blackout" <<<"$OUT16"; then
  echo "RTL SIM ERROR: missing PASS blackout marker" >&2
  exit 2
fi

echo "=== fullframe LINE_COUNT=16 ==="
set +e
OUTF="$("$BIN16" fullframe 2>&1)"
RCF=$?
set -e
printf '%s\n' "$OUTF"
echo "fullframe_lc16 true rc=$RCF"
if [[ "$RCF" -ne 0 ]]; then
  echo "RTL SIM ERROR: fullframe 720p scan failed" >&2
  exit "$RCF"
fi
if ! grep -q "PASS fullframe" <<<"$OUTF"; then
  echo "RTL SIM ERROR: missing PASS fullframe marker" >&2
  exit 2
fi

echo "PASS test_ddr_frame_store_l4_rtl_sim (lc8 RED rc=$RC8, lc16 blackout rc=$RC16, fullframe rc=$RCF)"
exit 0
