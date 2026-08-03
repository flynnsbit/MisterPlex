#!/usr/bin/env bash
# Forced-stall exact lane scoreboard (rd-duck: count-only accepts drop+dup).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OUT="$ROOT/build/verilator/present_npx_af_conserve"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
mkdir -p "$OUT"

run_one() {
  local tag=$1
  local def=$2
  local d="$OUT/$tag"
  mkdir -p "$d"
  rm -rf "$d/run"
  if ! "$RV" -Wno-fatal --binary --timing --top-module present_npx_af_conserve_tb \
    -Mdir "$d/run" $def \
    "$ROOT/tests/rtl/present_npx_af_conserve_tb.sv" \
    "$RTL/present_npx_path.sv" "$RTL/async_fifo.sv" >"$d/build.log" 2>&1; then
    echo "FAIL build $tag"
    tail -30 "$d/build.log"
    return 2
  fi
  set +e
  "$d/run/Vpresent_npx_af_conserve_tb" >"$d/run.log" 2>&1
  local rc=$?
  set -e
  cat "$d/run.log" || true
  return "$rc"
}

echo "GREEN scoreboard"
set +e
run_one green ""
grc=$?
set -e
echo "green rc=$grc"
if [[ $grc -ne 0 ]]; then echo "FAIL green rc=$grc"; exit 1; fi
grep -q "PASS present_npx_af_conserve" "$OUT/green/run.log" || { echo "FAIL green marker"; exit 1; }
grep -q "sb_exact=1" "$OUT/green/run.log" || { echo "FAIL missing sb_exact"; exit 1; }

echo "RED FAULT_LANE_SWAP (order break, count may match)"
set +e
run_one red "-GFAULT_LANE_SWAP=1"
rrc=$?
set -e
echo "red rc=$rrc"
if [[ $rrc -eq 0 ]] && grep -q "PASS present_npx_af_conserve" "$OUT/red/run.log"; then
  echo "FAIL RED lane-swap should not PASS"
  exit 1
fi
if ! grep -qE "FAIL sb|FAIL scoreboard|TB_FAIL|mism=" "$OUT/red/run.log"; then
  echo "FAIL RED did not report scoreboard mismatch"
  tail -30 "$OUT/red/run.log" || true
  exit 1
fi
echo "OK RED lane-swap caught rc=$rrc"

echo "PASS test_present_npx_af_conserve true rc=0"
exit 0
