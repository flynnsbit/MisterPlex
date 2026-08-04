#!/usr/bin/env bash
# Verilator: ddr_frame_abi_select 480p stay / 720p ABI + NEG 640x480.
# Soft-skip≠PASS. true rc direct. grep TB PASS marker (false-green guard).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
echo "=== test_ddr_frame_abi_select_rtl_sim EXECUTED ==="
OUT="$ROOT/build/verilator/ddr_frame_abi_select"
mkdir -p "$OUT"
"$RUN" --cc --exe --build --Mdir "$OUT" \
  --top-module ddr_frame_abi_select_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb_top.sv" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb.cpp"
echo "verilator_build true rc=$?"
set +e
LOG=$("$OUT/Vddr_frame_abi_select_tb_top" 2>&1)
SRC=$?
set -e
echo "$LOG"
echo "sim true rc=$SRC"
if [[ "$SRC" -ne 0 ]]; then
  echo "FAIL test_ddr_frame_abi_select_rtl_sim sim rc=$SRC" >&2
  exit "$SRC"
fi
if ! grep -q 'ddr_frame_abi_select: OK 480p stays' <<<"$LOG"; then
  echo "FAIL missing TB PASS marker" >&2
  exit 2
fi
echo "PASS test_ddr_frame_abi_select_rtl_sim"
