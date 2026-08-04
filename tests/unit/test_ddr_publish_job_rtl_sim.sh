#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
echo "=== test_ddr_publish_job_rtl_sim EXECUTED ==="
set +e; VER="$($RUN_VERILATOR --version 2>&1)"; RC=$?; set -e
[[ $RC -eq 0 ]] || { echo "verilator fail rc=$RC" >&2; exit ${RC:-3}; }
OUT="$ROOT/build/verilator/ddr_publish_job"
mkdir -p "$OUT"
"$RUN_VERILATOR" --cc --exe --build --Mdir "$OUT" \
  --top-module ddr_publish_job_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_publish_job_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_publish_job.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_i420_bank_geom.sv" \
  "$ROOT/tests/rtl/ddr_publish_job_tb.cpp"
echo "verilator_build true rc=$?"
"$OUT/Vddr_publish_job_tb_top"
echo "sim true rc=$?"
echo "PASS test_ddr_publish_job_rtl_sim"
