#!/usr/bin/env bash
# Bresenham V_TOTAL product + RED fixed-V negative case + exact-int mode.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OUT="$ROOT/build/verilator/bresenham_vtotal"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/bresenham_vtotal_tb.sv"
BRES="$RTL/present_vtotal_bresenham.sv"
CORE="$RTL/present_core.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
mkdir -p "$OUT"

echo "RTL SIM: $($RV --version 2>&1 | head -1)"

awk 'BEGIN{
  m_wrong=0.72476*705 + (1-0.72476)*706
  m_right=(1-0.72476)*705 + 0.72476*706
  if (m_right < 705.724 || m_right > 705.726) {
    printf("FAIL right mean %.10f\n", m_right) > "/dev/stderr"; exit 1
  }
  if (m_wrong < 705.275 || m_wrong > 705.276) {
    printf("FAIL wrong-mean band %.10f\n", m_wrong) > "/dev/stderr"; exit 1
  }
  d706=1285/1773
  d565=1028/1773
  if (d706 < 0.7247 || d706 > 0.7248) exit 1
  if (d565 < 0.5798 || d565 > 0.5799) exit 1
  clk=20000000; H=1182
  hz24=clk/(H*(1251250/1773))
  w24=24000/1001
  hz30=clk/(H*(1001000/1773))
  w30=30000/1001
  if (hz24-w24 < -1e-12 || hz24-w24 > 1e-12) exit 1
  if (hz30-w30 < -1e-12 || hz30-w30 > 1e-12) exit 1
  printf("OK PARENT MISS: 72.48%% duty is at V=706 (mean=%.6f); at 705 would mean=%.6f\n", m_right, m_wrong)
  printf("OK exact NTSC lock film=%.12f tv=%.12f\n", hz24, hz30)
}'

grep -q 'NTSC_FILM_NUM = 1285' "$BRES" || { echo "FAIL film num"; exit 1; }
grep -q 'NTSC_TV_NUM   = 1028' "$BRES" || { echo "FAIL tv num"; exit 1; }
grep -q 'FAULT_FIXED_VTOTAL' "$BRES" || { echo "FAIL no fixed red"; exit 1; }
grep -q 'FAULT_BRES_EXACT_INT' "$BRES" || { echo "FAIL no exact-int"; exit 1; }
grep -q 'present_vtotal_bresenham' "$CORE" || { echo "FAIL not wired in present_core"; exit 1; }
grep -q 'rt_vtotal(beam_vtot_req)' "$CORE" || { echo "FAIL rt_vtotal not beam_vtot_req"; exit 1; }
grep -q 'frame_tick(fstart)' "$CORE" || { echo "FAIL frame_tick not beam fstart"; exit 1; }
grep -q 'present_vtotal_bresenham.sv' "$QIP" || { echo "FAIL missing files.qip entry"; exit 1; }
# Comments may mention reserved bit34; fail only on real ports/logic.
if grep -E 'input[[:space:]].*fps_1001|\bfps_1001\b[[:space:]]*[,;=)]' "$BRES"; then
  echo "FAIL bresenham must not consume fps_1001"; exit 1
fi
if grep -nE 'bit[[:space:]]*34' "$BRES" | grep -viE 'RESERVED|reserved|later|not'; then
  echo "FAIL unexpected bit34 consumer"; exit 1
fi
if grep -E '\.swap_pending\s*\(\s*advance' "$CORE"; then
  echo "FAIL swap_pending tied to advance"; exit 1
fi
echo "OK RTL structure + qip + no bit34 + swap≠advance"

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module bresenham_vtotal_tb \
    -Mdir "$mdir" "$@" "$TB" "$BRES" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"
    tail -50 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"
    return 0
  fi
  set +e
  "$mdir/Vbresenham_vtotal_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
}

run_one green
GRC=$(cat "$OUT/green/sim.rc")
[[ "$GRC" -eq 0 ]] || { echo "FAIL GREEN rc=$GRC"; exit 1; }
grep -q "OK long-run lock n_hi=1285/1773" "$OUT/green/run.log" || { echo "FAIL film lock line"; exit 1; }
grep -q "OK long-run lock n_hi=1028/1773" "$OUT/green/run.log" || { echo "FAIL tv lock line"; exit 1; }
grep -q "PASS bresenham_vtotal_tb GREEN ntsc" "$OUT/green/run.log" || { echo "FAIL green pass"; exit 1; }
echo "OK GREEN NTSC Bresenham"

run_one red_fixed -DFAULT_FIXED_VTOTAL
RRC=$(cat "$OUT/red_fixed/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED rc=$RRC"; exit 1; }
grep -q "OK RED fixed V long-run" "$OUT/red_fixed/run.log" || { echo "FAIL red marker"; exit 1; }
grep -q "PASS bresenham_vtotal_tb RED fixed" "$OUT/red_fixed/run.log" || { echo "FAIL red pass"; exit 1; }
echo "OK RED fixed-V negative case (naive fixed fails NTSC lock)"

run_one green_int -DFAULT_BRES_EXACT_INT
IRC=$(cat "$OUT/green_int/sim.rc")
[[ "$IRC" -eq 0 ]] || { echo "FAIL INT rc=$IRC"; exit 1; }
grep -q "OK long-run lock n_hi=35/1773" "$OUT/green_int/run.log" || { echo "FAIL e24"; exit 1; }
grep -q "OK long-run lock n_hi=28/1773" "$OUT/green_int/run.log" || { echo "FAIL e30"; exit 1; }
echo "OK exact integer 24/30 mode"

echo "PASS test_bresenham_vtotal_impl true rc=0"
