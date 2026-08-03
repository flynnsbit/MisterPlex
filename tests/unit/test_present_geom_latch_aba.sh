#!/usr/bin/env bash
# B4: product epoch latch + FAULT_NO_EPOCH red twin REPRO.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
RV=scripts/run_verilator.sh
OUT=build/verilator/b4_latch_aba
rm -rf "$OUT"
mkdir -p "$OUT/product" "$OUT/fault"

common=(--cc --exe --build --top-module present_geom_latch_aba_tb_top
  -Wno-fatal
  -Ifpga/Plex_MiSTer/rtl
  fpga/Plex_MiSTer/rtl/present_geom_latch.sv
  tests/rtl/present_geom_latch_aba_tb_top.sv
  tests/rtl/present_geom_latch_aba_tb.cpp
  -CFLAGS "-std=c++17 -O2")

echo "== product (epoch required) =="
"$RV" "${common[@]}" --Mdir "$OUT/product" -o b4_product
set +e
"$OUT/product/b4_product" | tee "$OUT/product_run.txt"
prc=${PIPESTATUS[0]}
set -e
echo "product true rc=$prc"
[[ "$prc" -eq 0 ]]
grep -q "PASS B4 product" "$OUT/product_run.txt"

echo "== red twin FAULT_NO_EPOCH =="
"$RV" "${common[@]}" --Mdir "$OUT/fault" -DPRESENT_GEOM_LATCH_FAULT_NO_EPOCH -o b4_fault
set +e
FAULT_NO_EPOCH=1 "$OUT/fault/b4_fault" | tee "$OUT/fault_run.txt"
frc=${PIPESTATUS[0]}
set -e
echo "fault true rc=$frc"
[[ "$frc" -eq 0 ]]
grep -q "REPRO B4_ABA_NO_EPOCH" "$OUT/fault_run.txt"
echo "PASS test_present_geom_latch_aba"
