#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/cdc_pulse_toggle_tb.sv"
OUT="$ROOT/build/verilator/cdc_pulse_toggle"
mkdir -p "$OUT" "$ROOT/build"

run_one() {
  local fault="$1"
  local dir="$OUT/f${fault}"
  mkdir -p "$dir"
  local defs=()
  if [[ "$fault" == "1" ]]; then defs+=(-DFAULT_BARE_PULSE); fi
  echo "=== cdc_pulse_toggle FAULT=${fault} ==="
  verilator --binary -Wall -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module cdc_pulse_toggle_tb \
    -Mdir "$dir" \
    "${defs[@]}" \
    "$RTL/cdc_sync_bit.sv" \
    "$RTL/cdc_pulse_toggle.sv" \
    "$TB" \
    -o Vcdc_pulse
  local log="$ROOT/build/cdc_pulse_f${fault}.log"
  set +e
  "$dir/Vcdc_pulse" >"$log" 2>&1
  local rc=$?
  set -e
  echo "--- f${fault} log ---"
  tail -30 "$log"
  echo "sim_f${fault} true rc=${rc}"
  if grep -q '^FAIL ' "$log"; then
    echo "FAIL f${fault}"; exit 1
  fi
  if [[ "$fault" == "0" ]]; then
    grep -q 'PASS POS cdc_pulse_toggle' "$log" || { echo "FAIL POS"; exit 1; }
  else
    grep -q 'REPRO_OK NEG bare_pulse' "$log" || { echo "FAIL NEG"; exit 1; }
  fi
}

echo "=== test_cdc_pulse_toggle_rtl_sim EXECUTED ==="
command -v verilator >/dev/null
echo "RTL SIM: $(verilator --version | head -1)"
run_one 0
run_one 1
echo "PASS test_cdc_pulse_toggle_rtl_sim"
echo "true rc=0"
exit 0
