#!/usr/bin/env bash
# Bit-exact present_content_window PIPE_DEPTH=1 vs 2 (+ NEG fault twin).
# Soft-skip≠PASS. true rc direct. assert_sim_executed required.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
# shellcheck source=lib_rtl_sim_gate.sh
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
echo "=== test_present_content_window_pipe_rtl_sim EXECUTED ==="
rtl_sim_require_verilator "present_content_window_pipe"
OUT="$ROOT/build/verilator/present_content_window_pipe"
mkdir -p "$OUT"
"$RUN" --cc --exe --build --Mdir "$OUT" \
  --top-module present_content_window_pipe_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_content_window.sv" \
  "$ROOT/tests/rtl/present_content_window_pipe_tb_top.sv" \
  "$ROOT/tests/rtl/present_content_window_pipe_tb.cpp"
echo "verilator_build true rc=$?"
set +e
SIM_LOG="$("$OUT/Vpresent_content_window_pipe_tb_top" 2>&1)"
SIM_RC=$?
set -e
printf '%s\n' "$SIM_LOG"
echo "sim true rc=$SIM_RC"
if [[ "$SIM_RC" -ne 0 ]]; then
  echo "FAIL present_content_window_pipe: TB rc=$SIM_RC" >&2
  exit "$SIM_RC"
fi
assert_sim_executed "present_content_window_pipe" "$SIM_LOG" \
  "present_content_window_pipe: OK bit-exact POS + NEG fault" \
  "OK NEG" \
  "OK POS" \
  "latency_offset_ce=1"
echo "PASS test_present_content_window_pipe_rtl_sim"
