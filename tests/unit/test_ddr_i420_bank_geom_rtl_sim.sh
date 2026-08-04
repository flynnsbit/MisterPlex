#!/usr/bin/env bash
# Verilator sim for ddr_i420_bank_geom (presentation bank ABI, M10K=0).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
echo "=== test_ddr_i420_bank_geom_rtl_sim EXECUTED ==="
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing PASS without simulation." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi
echo "RTL SIM: using $VERILATOR_VERSION" >&2

RTL="$ROOT/fpga/Plex_MiSTer/rtl/ddr_i420_bank_geom.sv"
TOP="$ROOT/tests/rtl/ddr_i420_bank_geom_tb_top.sv"
TB="$ROOT/tests/rtl/ddr_i420_bank_geom_tb.cpp"
OUT="$ROOT/build/verilator/ddr_i420_bank_geom"
for f in "$RTL" "$TOP" "$TB"; do
  [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
done
mkdir -p "$OUT"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$OUT" \
  --top-module ddr_i420_bank_geom_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
echo "verilator_build true rc=$?"
"$OUT/Vddr_i420_bank_geom_tb_top"
echo "sim true rc=$?"
echo "PASS test_ddr_i420_bank_geom_rtl_sim"
