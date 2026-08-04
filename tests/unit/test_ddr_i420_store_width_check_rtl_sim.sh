#!/usr/bin/env bash
# Verilator: 720p I420 plane widths + NEG narrow counters.
# Soft-skip≠PASS. true rc direct. grep TB PASS marker (false-green guard).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
echo "=== test_ddr_i420_store_width_check_rtl_sim EXECUTED ==="
OUT="$ROOT/build/verilator/ddr_i420_store_width_check"
mkdir -p "$OUT"
"$RUN" --cc --exe --build --Mdir "$OUT" \
  --top-module ddr_i420_store_width_check_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_i420_store_width_check_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_i420_store_width_check.sv" \
  "$ROOT/tests/rtl/ddr_i420_store_width_check_tb.cpp"
echo "verilator_build true rc=$?"
set +e
LOG=$("$OUT/Vddr_i420_store_width_check_tb_top" 2>&1)
SRC=$?
set -e
echo "$LOG"
echo "sim true rc=$SRC"
if [[ "$SRC" -ne 0 ]]; then
  echo "FAIL test_ddr_i420_store_width_check_rtl_sim sim rc=$SRC" >&2
  exit "$SRC"
fi
if ! grep -q 'ddr_i420_store_width_check: OK 720p widths' <<<"$LOG"; then
  echo "FAIL missing TB PASS marker" >&2
  exit 2
fi
echo "PASS test_ddr_i420_store_width_check_rtl_sim"
