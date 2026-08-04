#!/usr/bin/env bash
# arbiter4 scanout WC bound POS + NEG (FAULT_NO_M0_YIELD).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/ddr_arbiter4_scanout_bound_tb.sv"
OUT="$ROOT/build/verilator/ddr_arb4_bound"
mkdir -p "$OUT" "$ROOT/build"

run_one() {
  local tag="$1"
  local dir="$OUT/${tag}"
  mkdir -p "$dir"
  echo "=== arb4_bound tag=${tag} ==="
  local defs=()
  if [[ "$tag" == "neg" ]]; then defs+=(-DFAULT_NO_M0_YIELD); fi
  verilator --binary -Wall -Wno-fatal -Wno-TIMESCALEMOD \
    --top-module ddr_arbiter4_scanout_bound_tb \
    -Mdir "$dir" \
    "${defs[@]}" \
    "$RTL/async_fifo.sv" \
    "$RTL/ddr_bus_arbiter4.sv" \
    "$TB" \
    -o Varb4
  local log="$ROOT/build/ddr_arb4_bound_${tag}.log"
  set +e
  "$dir/Varb4" >"$log" 2>&1
  local rc=$?
  set -e
  tail -40 "$log"
  echo "sim_${tag} true rc=${rc}"
  if grep -q '^FAIL ' "$log"; then echo "FAIL ${tag}"; exit 1; fi
  if [[ "$tag" == "pos" ]]; then
    grep -q 'PASS POS scanout' "$log" || { echo "FAIL POS"; exit 1; }
  else
    grep -q 'REPRO_OK NEG FAULT_NO_M0_YIELD' "$log" || { echo "FAIL NEG"; exit 1; }
  fi
}

echo "=== test_ddr_arbiter4_scanout_bound EXECUTED ==="
command -v verilator >/dev/null
run_one pos
run_one neg
echo "PASS test_ddr_arbiter4_scanout_bound"
echo "true rc=0"
exit 0
