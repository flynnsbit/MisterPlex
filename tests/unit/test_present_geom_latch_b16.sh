#!/usr/bin/env bash
# B16 atomic promote + ABI#2 q5 reserved reject + red twins.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
RV=scripts/run_verilator.sh
OUT=build/verilator/b16_latch
rm -rf "$OUT"
mkdir -p "$OUT/product" "$OUT/fault_imm" "$OUT/fault_res" "$OUT/prod_res"

common=(--cc --exe --build --top-module present_geom_latch_b16_tb_top
  -Wno-fatal
  -Ifpga/Plex_MiSTer/rtl
  fpga/Plex_MiSTer/rtl/present_geom_latch.sv
  tests/rtl/present_geom_latch_b16_tb_top.sv
  tests/rtl/present_geom_latch_b16_tb.cpp
  -CFLAGS "-std=c++17 -O2")

echo "== B16 product (stage + frame_boundary + q5) =="
"$RV" "${common[@]}" --Mdir "$OUT/product" -o b16_product
set +e
"$OUT/product/b16_product" >"$OUT/product_run.txt" 2>&1
prc=$?
set -e
cat "$OUT/product_run.txt"
echo "product true rc=$prc"
[[ "$prc" -eq 0 ]]
grep -q "PASS B16" "$OUT/product_run.txt"

echo "== B16 red twin FAULT_IMMEDIATE_COMMIT (rc=2) =="
"$RV" "${common[@]}" --Mdir "$OUT/fault_imm" -DPRESENT_GEOM_LATCH_FAULT_IMMEDIATE_COMMIT -o b16_fault_imm
set +e
FAULT_IMMEDIATE_COMMIT=1 "$OUT/fault_imm/b16_fault_imm" >"$OUT/fault_run.txt" 2>&1
frc=$?
set -e
cat "$OUT/fault_run.txt"
echo "fault_imm true rc=$frc"
[[ "$frc" -eq 2 ]]
grep -q "REPRO B16_IMMEDIATE_COMMIT" "$OUT/fault_run.txt"

echo "== ABI#2 product rejects q5 reserved nonzero =="
# reuse product binary
set +e
TEST_Q5_RESERVED=1 "$OUT/product/b16_product" >"$OUT/prod_res_run.txt" 2>&1
rrc=$?
set -e
cat "$OUT/prod_res_run.txt"
echo "prod_reserved true rc=$rrc"
[[ "$rrc" -eq 0 ]]
grep -q "rejects q5 reserved" "$OUT/prod_res_run.txt"

echo "== ABI#2 red twin FAULT_IGNORE_Q5_RESERVED (rc=2) =="
"$RV" "${common[@]}" --Mdir "$OUT/fault_res" -DPRESENT_GEOM_LATCH_FAULT_IGNORE_Q5_RESERVED -o b16_fault_res
set +e
FAULT_IGNORE_Q5_RESERVED=1 TEST_Q5_RESERVED=1 "$OUT/fault_res/b16_fault_res" >"$OUT/fault_res_run.txt" 2>&1
frrc=$?
set -e
cat "$OUT/fault_res_run.txt"
echo "fault_res true rc=$frrc"
[[ "$frrc" -eq 2 ]]
grep -q "REPRO Q5_RESERVED_ACCEPTED" "$OUT/fault_res_run.txt"

echo "== B16 red twin FAULT_LOSE_COINCIDENT (rc=2) =="
mkdir -p "$OUT/fault_coin"
"$RV" "${common[@]}" --Mdir "$OUT/fault_coin" -DPRESENT_GEOM_LATCH_FAULT_LOSE_COINCIDENT -o b16_fault_coin
set +e
FAULT_LOSE_COINCIDENT=1 "$OUT/fault_coin/b16_fault_coin" >"$OUT/fault_coin_run.txt" 2>&1
crc=$?
set -e
cat "$OUT/fault_coin_run.txt"
echo "fault_coin true rc=$crc"
[[ "$crc" -eq 2 ]]
grep -q "REPRO B16_LOSE_COINCIDENT" "$OUT/fault_coin_run.txt"

echo "== B16 red twin FAULT_NO_DAR_BLACKOUT same-size 4:3→16:9 (rc=2) =="
mkdir -p "$OUT/fault_dar"
"$RV" "${common[@]}" --Mdir "$OUT/fault_dar" -DPRESENT_GEOM_LATCH_FAULT_NO_DAR_BLACKOUT -o b16_fault_dar
set +e
FAULT_NO_DAR_BLACKOUT=1 "$OUT/fault_dar/b16_fault_dar" >"$OUT/fault_dar_run.txt" 2>&1
drc=$?
set -e
cat "$OUT/fault_dar_run.txt"
echo "fault_dar true rc=$drc"
[[ "$drc" -eq 2 ]]
grep -q "REPRO B16_NO_DAR_BLACKOUT" "$OUT/fault_dar_run.txt"

echo "PASS test_present_geom_latch_b16 product+q5+DAR_blackout+REPROs"
