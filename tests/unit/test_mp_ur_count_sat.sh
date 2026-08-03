#!/usr/bin/env bash
# UR count saturate: 0x7ffe+2 must stick at 0x7fff (rd-duck 15-bit wrap).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OUT="$ROOT/build/verilator/mp_ur_count_sat"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
mkdir -p "$OUT"

# Product source must not contain the buggy 15-bit compare form.
if grep -n "15'(mp_rd_ur_count) + 15'(mp_rd_ur_delta) < 15'h7fff" "$RTL/present_core.sv"; then
  echo "FAIL product still has 15-bit wrap-before-compare"
  exit 1
fi
if ! grep -q "16'({1'b0, mp_rd_ur_count}) + 16'(mp_rd_ur_delta)" "$RTL/present_core.sv"; then
  echo "FAIL product missing 16-bit sat sum on ur count"
  exit 1
fi
if ! grep -q "mp_ur_sum16" "$RTL/present_core.sv"; then
  echo "FAIL product missing 16-bit ur_sum combine"
  exit 1
fi

run_one() {
  local tag=$1 def=$2
  local d="$OUT/$tag"
  mkdir -p "$d"; rm -rf "$d/run"
  "$RV" -Wno-fatal --binary --timing --top-module mp_ur_count_sat_tb \
    -Mdir "$d/run" $def \
    "$ROOT/tests/rtl/mp_ur_count_sat_tb.sv" >"$d/build.log" 2>&1
  set +e
  "$d/run/Vmp_ur_count_sat_tb" >"$d/run.log" 2>&1
  local rc=$?
  set -e
  cat "$d/run.log"
  return $rc
}

echo "GREEN fixed sat"
set +e; run_one green ""; grc=$?; set -e
echo "green rc=$grc"
[[ $grc -eq 0 ]] || { echo "FAIL green"; exit 1; }
grep -q "PASS mp_ur_count_sat boundary" "$OUT/green/run.log" || { echo "FAIL green marker"; exit 1; }

echo "RED wrap bug"
set +e; run_one red "-GRED_WRAP_BUG=1"; rrc=$?; set -e
echo "red rc=$rrc"
if grep -q "PASS mp_ur_count_sat boundary" "$OUT/red/run.log"; then
  echo "FAIL RED must not pass boundary green marker"
  exit 1
fi
grep -q "PASS mp_ur_count_sat RED_WRAP_BUG caught" "$OUT/red/run.log" || {
  echo "FAIL RED marker"; tail -20 "$OUT/red/run.log"; exit 1; }

echo "PASS test_mp_ur_count_sat true rc=0"
exit 0
