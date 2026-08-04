#!/usr/bin/env bash
# Gate: FRAME 1280x720 selects 720p DDR ABI without L4; lines floor 8→16.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
MDIR="$ROOT/build/verilator/ddr_frame_abi_select"
mkdir -p "$MDIR"
echo "PRE-REG: MULTI-class FRAME 1280x720 → 720p bank; 480p unchanged; lines 16"
verilator --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module ddr_frame_abi_select_tb_top \
  -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb_top.sv" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb.cpp"
set +e
OUT="$("$MDIR/Vddr_frame_abi_select_tb_top" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "$OUT" | grep -q PASS || { echo "FAIL abi_select: no PASS in TB out" >&2; exit 1; }
[[ "$RC" -eq 0 ]] || exit "$RC"
echo "ddr_frame_abi_select Verilator gate PASS"
