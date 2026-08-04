#!/usr/bin/env bash
# L4 720p ddr_frame_store reader gates:
#  1) blackout LINE_COUNT=8  → RED  (underrun under 500us model)
#  2) blackout LINE_COUNT=16 → GREEN
#  3) fullframe LINE_COUNT=16 1280x720 + cycle budget
#  4) boundaries (last line/MB-row + bank0→bank1 swap)
#  5) awkward height 718 (not multiple of 16)
#  6) neg_count → RED (wrong pixel count 1280*480)
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
echo "PREREG: active_scan_720=921600 beam_budget=999744 blank_margin=78144" >&2

build_one() {
  local tag="$1"
  shift
  local dir="$ROOT/build/verilator/ddr_frame_store_l4_${tag}"
  local bin="$dir/Vddr_frame_store_l4_tb"
  mkdir -p "$dir"
  # shellcheck disable=SC2086
  "$RUN_VERILATOR" --cc --exe --build --Mdir "$dir" \
    --top-module ddr_frame_store_l4_tb -Wno-fatal \
    "$@" \
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

echo "=== build LINE_COUNT=8 (720p) ==="
BIN8="$(build_one lc8 -GLINE_COUNT=8 -GFRAME_H=720 -GCODED_H=720 -GDISPLAY_H=720)"
echo "BIN8=$BIN8"
echo "=== build LINE_COUNT=16 (720p) ==="
BIN16="$(build_one lc16 -GLINE_COUNT=16 -GFRAME_H=720 -GCODED_H=720 -GDISPLAY_H=720)"
echo "BIN16=$BIN16"
echo "=== build LINE_COUNT=16 awkward H=718 ==="
BINAWK="$(build_one awk718 -GLINE_COUNT=16 -GFRAME_H=718 -GCODED_H=718 -GDISPLAY_H=718)"
echo "BINAWK=$BINAWK"

echo "=== blackout LINE_COUNT=8 (expect RED / underrun) ==="
export L4_TB_W=1280 L4_TB_H=720
set +e
OUT8="$("$BIN8" blackout 2>&1)"
RC8=$?
set -e
printf '%s\n' "$OUT8"
echo "blackout_lc8 true rc=$RC8"
if [[ "$RC8" -eq 0 ]]; then
  echo "RTL SIM ERROR: LINE_COUNT=8 blackout was GREEN — must underrun" >&2
  exit 2
fi
if ! grep -q "FAIL blackout: line buffer underran" <<<"$OUT8"; then
  echo "RTL SIM ERROR: LINE_COUNT=8 missing underrun FAIL marker" >&2
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

echo "=== fullframe LINE_COUNT=16 + cycle budget ==="
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
if ! grep -q "delta_vs_beam_budget=" <<<"$OUTF"; then
  echo "RTL SIM ERROR: missing cycle budget report" >&2
  exit 2
fi
# Active scan must not exceed beam budget (CRITICAL printed + rc=1 if so).
if grep -q "CRITICAL: active scan cycles exceed" <<<"$OUTF"; then
  echo "RTL SIM ERROR: cycle budget exceeded" >&2
  exit 2
fi

echo "=== boundaries (last line / MB-row / bank swap) ==="
set +e
OUTB="$("$BIN16" boundaries 2>&1)"
RCB=$?
set -e
printf '%s\n' "$OUTB"
echo "boundaries_lc16 true rc=$RCB"
if [[ "$RCB" -ne 0 ]]; then
  echo "RTL SIM ERROR: boundaries failed" >&2
  exit "$RCB"
fi
if ! grep -q "PASS boundaries" <<<"$OUTB"; then
  echo "RTL SIM ERROR: missing PASS boundaries marker" >&2
  exit 2
fi

echo "=== awkward height 718 (not multiple of 16) ==="
export L4_TB_W=1280 L4_TB_H=718
set +e
OUTA="$("$BINAWK" awkward 2>&1)"
RCA=$?
set -e
printf '%s\n' "$OUTA"
echo "awkward_h718 true rc=$RCA"
if [[ "$RCA" -ne 0 ]]; then
  echo "RTL SIM ERROR: awkward height failed" >&2
  exit "$RCA"
fi
if ! grep -q "PASS awkward" <<<"$OUTA"; then
  echo "RTL SIM ERROR: missing PASS awkward marker" >&2
  exit 2
fi
export L4_TB_W=1280 L4_TB_H=720

echo "=== neg_count (expect RED — wrong 1280*480 pixel count) ==="
set +e
OUTN="$("$BIN16" neg_count 2>&1)"
RCN=$?
set -e
printf '%s\n' "$OUTN"
echo "neg_count true rc=$RCN"
if [[ "$RCN" -eq 0 ]]; then
  echo "RTL SIM ERROR: neg_count was GREEN — wrong pixel expect must FAIL" >&2
  exit 2
fi
if ! grep -q "FAIL fullframe: pixels=" <<<"$OUTN"; then
  echo "RTL SIM ERROR: neg_count missing pixels FAIL marker" >&2
  exit 2
fi
echo "OK red-check: neg_count rejects 1280*480 expectation (rc=$RCN)"

# Positive twin: same binary with correct expect must GREEN (teeth on both sides).
echo "=== pos_count twin (expect GREEN — 921600) ==="
set +e
OUTP="$("$BIN16" fullframe --expect-pixels 921600 2>&1)"
RCP=$?
set -e
printf '%s\n' "$OUTP"
echo "pos_count true rc=$RCP"
if [[ "$RCP" -ne 0 ]]; then
  echo "RTL SIM ERROR: correct expect-pixels failed" >&2
  exit "$RCP"
fi

echo "PASS test_ddr_frame_store_l4_rtl_sim (lc8 RED rc=$RC8, lc16 blackout rc=$RC16, fullframe rc=$RCF, boundaries rc=$RCB, awkward rc=$RCA, neg_count RED rc=$RCN, pos_count rc=$RCP)"
exit 0
