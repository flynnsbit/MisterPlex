#!/usr/bin/env bash
# First/last RGB+DE oracle + RED direct-sync skew (rd-duck same-clock trap).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OUT="$ROOT/build/verilator/present_npx_first_last_de"
mkdir -p "$OUT"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
PC="$PC"

run_one() {
  local tag=$1
  local def=$2
  local dir="$OUT/$tag"
  mkdir -p "$dir"
  rm -rf "$dir/run"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module present_npx_first_last_de_tb \
    -Mdir "$dir/run" $def \
    "$ROOT/tests/rtl/present_npx_first_last_de_tb.sv" \
    "$RTL/present_npx_path.sv" "$RTL/async_fifo.sv" \
    >"$dir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ $brc -ne 0 ]]; then
    echo "FAIL build $tag rc=$brc"
    tail -40 "$dir/build.log"
    return 1
  fi
  set +e
  "$dir/run/Vpresent_npx_first_last_de_tb" >"$dir/run.log" 2>&1
  local rc=$?
  set -e
  cat "$dir/run.log"
  return $rc
}

echo "GREEN INCLUDE_SYNC FIFO-aligned DE"
run_one green ""
grc=$?
if [[ $grc -ne 0 ]]; then echo "FAIL green rc=$grc"; exit 1; fi
grep -q "PASS present_npx_first_last_de first/last" "$OUT/green/run.log" || {
  echo "FAIL green marker"; exit 1; }

echo "RED_DIRECT_SYNC (must catch skew)"
run_one red "-GRED_DIRECT_SYNC=1"
rrc=$?
if [[ $rrc -ne 0 ]]; then echo "FAIL red rc=$rrc (should PASS catch)"; exit 1; fi
grep -q "PASS present_npx_first_last_de RED_DIRECT_SYNC" "$OUT/red/run.log" || {
  echo "FAIL red marker"; exit 1; }

# Structural: product same-clock must INCLUDE_SYNC and use mp_out_hb
if ! grep -q "localparam bit MP_INCLUDE_SYNC = 1'b1" "$PC"; then
  echo "FAIL present_core MP_INCLUDE_SYNC not hard-1"
  exit 1
fi
if grep -n "wire mp_hb_d = mp_hb" "$PC"; then
  echo "FAIL present_core still uses direct beam mp_hb for DE"
  exit 1
fi
if ! grep -q "wire mp_hb_d = mp_out_hb" "$PC"; then
  echo "FAIL present_core missing FIFO sideband mp_out_hb"
  exit 1
fi
if ! grep -q "vsync_pulse(mp_out_fs)" "$PC"; then
  echo "FAIL present_core vsync_pulse not FIFO-aligned mp_out_fs"
  exit 1
fi
# BEAM_960 must not be the MP path
if ! grep -q "Do NOT implement BEAM_960 by parameterizing MULTI_PIXEL" "$PC"; then
  echo "FAIL missing BEAM_960 vs MP separation comment"
  exit 1
fi

echo "PASS test_present_npx_first_last_de true rc=0"
exit 0
