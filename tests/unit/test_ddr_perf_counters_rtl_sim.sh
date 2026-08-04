#!/usr/bin/env bash
# ddr_perf_counters POS + NEG (FAULT_MISCOUNT_STALL, FAULT_MISBIN_LAT).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/ddr_perf_counters_tb.sv"
OUT="$ROOT/build/verilator/ddr_perf_counters"
mkdir -p "$OUT" "$ROOT/build"

run_one() {
  local tag="$1"
  local dir="$OUT/${tag}"
  mkdir -p "$dir"
  echo "=== ddr_perf_counters tag=${tag} ==="
  local defs=()
  if [[ "$tag" == "stall" ]]; then defs+=(-DFAULT_MISCOUNT_STALL); fi
  if [[ "$tag" == "bin" ]]; then defs+=(-DFAULT_MISBIN_LAT); fi
  verilator --binary -Wall -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module ddr_perf_counters_tb \
    -Mdir "$dir" \
    "${defs[@]}" \
    "$RTL/ddr_perf_counters.sv" \
    "$TB" \
    -o Vperf
  local log="$ROOT/build/ddr_perf_counters_${tag}.log"
  set +e
  "$dir/Vperf" >"$log" 2>&1
  local rc=$?
  set -e
  echo "--- ${tag} log ---"
  tail -40 "$log"
  echo "sim_${tag} true rc=${rc}"
  if grep -q '^FAIL ' "$log"; then
    echo "FAIL ${tag}: FAIL line"; exit 1
  fi
  case "$tag" in
    pos)
      grep -q 'PASS POS beats' "$log" || { echo "FAIL POS"; exit 1; }
      grep -q 'bin0=1 bin2=1' "$log" || { echo "FAIL POS bins"; exit 1; }
      ;;
    stall)
      grep -q 'REPRO_OK NEG FAULT_MISCOUNT_STALL' "$log" || { echo "FAIL NEG stall"; exit 1; }
      ;;
    bin)
      grep -q 'REPRO_OK NEG FAULT_MISBIN_LAT' "$log" || { echo "FAIL NEG bin"; exit 1; }
      ;;
  esac
}

echo "=== test_ddr_perf_counters_rtl_sim EXECUTED ==="
command -v verilator >/dev/null
echo "RTL SIM: $(verilator --version | head -1)"
run_one pos
run_one stall
run_one bin
echo "PASS test_ddr_perf_counters_rtl_sim"
echo "true rc=0"
exit 0
