#!/usr/bin/env bash
# FAULT twin then product: ddr_frame_dma + arbiter3 under present load.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
RTL_DMA="$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_dma.sv"
RTL_ARB="$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter3.sv"
RTL_FIFO="$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
TB="$ROOT/tests/rtl/ddr_frame_dma_contended_tb.sv"
OUT="$ROOT/build/verilator/ddr_frame_dma_contended"
mkdir -p "$OUT" "$ROOT/build"

echo "=== test_ddr_frame_dma_contended_rtl_sim EXECUTED ==="
command -v verilator >/dev/null
echo "RTL SIM: $(verilator --version | head -1)"

run_one() {
  local mode="$1"
  local def=()
  local top_dir="$OUT/$mode"
  mkdir -p "$top_dir"
  if [[ "$mode" == "fault" ]]; then
    def+=(-DDDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM)
  fi
  verilator --binary -Wall -Wno-fatal \
    --top-module ddr_frame_dma_contended_tb \
    -Mdir "$top_dir" \
    "${def[@]}" \
    "$RTL_DMA" "$RTL_ARB" "$RTL_FIFO" "$TB" \
    -o Vdma_contended
  local log="$ROOT/build/dma_contended_${mode}.log"
  set +e
  "$top_dir/Vdma_contended" >"$log" 2>&1
  local rc=$?
  set -e
  echo "--- ${mode} log ---"
  tail -30 "$log"
  echo "${mode} true rc=$rc"
  if grep -q '^FAIL ' "$log"; then
    echo "FAIL ${mode}: FAIL line in log"; exit 1
  fi
  if [[ "$mode" == "fault" ]]; then
    grep -q 'REPRO_OK FAULT' "$log" || { echo "FAIL fault REPRO"; exit 1; }
  else
    grep -q 'PASS G0' "$log" || { echo "FAIL product G0"; exit 1; }
    grep -q 'PASS G1 ' "$log" || { echo "FAIL product G1"; exit 1; }
    grep -q 'PASS G1b' "$log" || { echo "FAIL product G1b"; exit 1; }
    grep -q 'fabric_contended_beats_arm' "$log" || { echo "FAIL beats arm"; exit 1; }
    grep -q 'PASS ddr_frame_dma_contended_tb all' "$log" || { echo "FAIL product PASS"; exit 1; }
  fi
}

echo "=== A) FAULT sticky-no-quantum (expect REPRO_OK) ==="
run_one fault
echo "=== B) PRODUCT quantum (expect PASS all) ==="
run_one product
echo "PASS test_ddr_frame_dma_contended_rtl_sim"
echo "true rc=0"
exit 0
