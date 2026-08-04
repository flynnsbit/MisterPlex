#!/usr/bin/env bash
# Verilator: fabric/PL330 publish copy budget PREREG + honesty bits.
# Soft-skip≠PASS. true rc direct. grep TB PASS marker (false-green guard).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
echo "=== test_ddr_publish_copy_budget_rtl_sim EXECUTED ==="
OUT="$ROOT/build/verilator/ddr_publish_copy_budget"
mkdir -p "$OUT"
"$RUN" --cc --exe --build --Mdir "$OUT" \
  --top-module ddr_publish_copy_budget_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_publish_copy_budget_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_publish_copy_budget.sv" \
  "$ROOT/tests/rtl/ddr_publish_copy_budget_tb.cpp"
echo "verilator_build true rc=$?"
set +e
LOG=$("$OUT/Vddr_publish_copy_budget_tb_top" 2>&1)
SRC=$?
set -e
echo "$LOG"
echo "sim true rc=$SRC"
if [[ "$SRC" -ne 0 ]]; then
  echo "FAIL test_ddr_publish_copy_budget_rtl_sim sim rc=$SRC" >&2
  exit "$SRC"
fi
if ! grep -q 'ddr_publish_copy_budget: OK PREREG locked' <<<"$LOG"; then
  echo "FAIL missing TB PASS marker" >&2
  exit 2
fi
echo "PASS test_ddr_publish_copy_budget_rtl_sim"
