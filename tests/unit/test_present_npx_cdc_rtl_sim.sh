#!/usr/bin/env bash
# present_npx_path dual-clock CDC: POS bit-exact + FAULT twins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/present_npx_cdc_tb.sv"
OUT="$ROOT/build/verilator/present_npx_cdc"
mkdir -p "$OUT" "$ROOT/build"

run_one() {
  local mode="$1"
  local dir="$OUT/m${mode}"
  mkdir -p "$dir"
  echo "=== present_npx_cdc FAULT_MODE=${mode} ==="
  verilator --binary -Wall -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module present_npx_cdc_tb \
    -Mdir "$dir" \
    -DFAULT_MODE=${mode} \
    "$RTL/async_fifo.sv" \
    "$RTL/cdc_sync_bit.sv" \
    "$RTL/present_npx_path.sv" \
    "$TB" \
    -o Vnpx_cdc
  local log="$ROOT/build/present_npx_cdc_m${mode}.log"
  set +e
  "$dir/Vnpx_cdc" >"$log" 2>&1
  local rc=$?
  set -e
  echo "--- m${mode} log ---"
  tail -40 "$log"
  echo "sim_m${mode} true rc=${rc}"
  if grep -q '^FAIL ' "$log"; then
    echo "FAIL m${mode}: FAIL line"; exit 1
  fi
  if [[ "$mode" == "0" ]]; then
    grep -q 'PASS G0 dual_clock bit_exact' "$log" || { echo "FAIL POS G0"; exit 1; }
  elif [[ "$mode" == "2" ]]; then
    grep -q 'REPRO_OK NEG_B' "$log" || { echo "FAIL NEG_B"; exit 1; }
  else
    grep -q 'REPRO_OK FAULT_NO_PREFILL_SYNC' "$log" || { echo "FAIL FAULT1"; exit 1; }
  fi
  return 0
}

echo "=== test_present_npx_cdc_rtl_sim EXECUTED ==="
command -v verilator >/dev/null
echo "RTL SIM: $(verilator --version | head -1)"
run_one 0
run_one 2
run_one 1
echo "PASS test_present_npx_cdc_rtl_sim"
echo "true rc=0"
exit 0
