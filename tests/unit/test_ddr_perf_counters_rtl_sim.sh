#!/usr/bin/env bash
# ddr_perf_counters POS + NEG (FAULT_MISCOUNT_STALL).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/ddr_perf_counters_tb.sv"
OUT="$ROOT/build/verilator/ddr_perf_counters"
mkdir -p "$OUT" "$ROOT/build"

run_one() {
  local fault="$1"
  local dir="$OUT/f${fault}"
  mkdir -p "$dir"
  echo "=== ddr_perf_counters FAULT=${fault} ==="
  local defs=()
  if [[ "$fault" == "1" ]]; then defs+=(-DFAULT_MISCOUNT_STALL); fi
  verilator --binary -Wall -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module ddr_perf_counters_tb \
    -Mdir "$dir" \
    "${defs[@]}" \
    "$RTL/ddr_perf_counters.sv" \
    "$TB" \
    -o Vperf
  local log="$ROOT/build/ddr_perf_counters_f${fault}.log"
  set +e
  "$dir/Vperf" >"$log" 2>&1
  local rc=$?
  set -e
  echo "--- f${fault} log ---"
  tail -30 "$log"
  echo "sim_f${fault} true rc=${rc}"
  if grep -q '^FAIL ' "$log"; then
    echo "FAIL f${fault}: FAIL line"; exit 1
  fi
  if [[ "$fault" == "0" ]]; then
    grep -q 'PASS POS beats' "$log" || { echo "FAIL POS"; exit 1; }
  else
    grep -q 'REPRO_OK NEG FAULT_MISCOUNT_STALL' "$log" || { echo "FAIL NEG"; exit 1; }
  fi
}

echo "=== test_ddr_perf_counters_rtl_sim EXECUTED ==="
command -v verilator >/dev/null
echo "RTL SIM: $(verilator --version | head -1)"
run_one 0
run_one 1
echo "PASS test_ddr_perf_counters_rtl_sim"
echo "true rc=0"
exit 0
