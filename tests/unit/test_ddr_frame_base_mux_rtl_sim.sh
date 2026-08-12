#!/usr/bin/env bash
# Verilator: DYN_BASE_EN=0 product identity + NEG ignore-dyn;
#            DYN_BASE_EN=1 dyn select + NEG fallback.
# Soft-skip≠PASS. true rc direct.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
TB="$ROOT/tests/rtl/ddr_frame_base_mux_tb.cpp"
echo "=== test_ddr_frame_base_mux_rtl_sim EXECUTED ==="

run_one() {
  local mode="$1"  # 0 or 1
  local out="$ROOT/build/verilator/ddr_frame_base_mux_dyn${mode}"
  mkdir -p "$out"
  set +e
  "$RUN" -sv -cc --exe --build -Mdir "$out" \
    -CFLAGS "-std=c++17 -O2 -DDYN_BASE_EN_TB=${mode}" \
    -GDYN_BASE_EN=${mode} \
    --top-module ddr_frame_base_mux \
    "$RTL" "$TB"
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL build dyn=${mode} rc=$brc" >&2
    exit "$brc"
  fi
  set +e
  local log
  log=$("$out/Vddr_frame_base_mux" 2>&1)
  local src=$?
  set -e
  echo "$log"
  echo "sim dyn=${mode} true rc=$src"
  if [[ "$src" -ne 0 ]]; then
    echo "FAIL sim dyn=${mode}" >&2
    exit "$src"
  fi
  if [[ "$mode" -eq 0 ]]; then
    grep -q 'PASS ddr_frame_base_mux_tb fixed_identity+NEG_ignore_dyn' <<<"$log" \
      || { echo "FAIL missing fixed PASS marker" >&2; exit 2; }
  else
    grep -q 'PASS ddr_frame_base_mux_tb dyn_select+NEG_fallback' <<<"$log" \
      || { echo "FAIL missing dyn PASS marker" >&2; exit 2; }
  fi
}

run_one 0
run_one 1
echo "OK test_ddr_frame_base_mux_rtl_sim both modes"
