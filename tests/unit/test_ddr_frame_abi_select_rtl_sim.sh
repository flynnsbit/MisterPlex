#!/usr/bin/env bash
# Soft-skip≠PASS. true rc direct. assert_sim_executed required (false-green guard).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
# shellcheck source=lib_rtl_sim_gate.sh
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
echo "=== test_ddr_frame_abi_select_rtl_sim EXECUTED ==="
rtl_sim_require_verilator "ddr_frame_abi_select"
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
SIM_LOG="$("$OUT/Vddr_frame_abi_select_tb_top" 2>&1)"
SIM_RC=$?
set -e
printf '%s\n' "$SIM_LOG"
echo "sim true rc=$SIM_RC"
if [[ "$SIM_RC" -ne 0 ]]; then
  echo "FAIL ddr_frame_abi_select: TB rc=$SIM_RC" >&2
  exit "$SIM_RC"
fi
assert_sim_executed "ddr_frame_abi_select" "$SIM_LOG" \
  "ddr_frame_abi_select: OK" \
  "NEG 640x480"
echo "PASS test_ddr_frame_abi_select_rtl_sim"
