#!/usr/bin/env bash
# B20 integrated app-shadow + beam NBA lag (rd-duck).
# GREEN feed-forward; GREEN hold-cover without FF; RED island without FF+hold.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OUT="$ROOT/build/verilator/b20_integrated_app_beam"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
TB="$ROOT/tests/rtl/b20_integrated_app_beam_tb.sv"
mkdir -p "$OUT"

echo "RTL SIM: $($RV --version 2>&1 | head -1)"

# Structural product path
grep -q 'b20_swap_armed' "$CORE" || { echo "FAIL no b20_swap_armed"; exit 1; }
grep -q 'b20_swap_armed ? content_w : app_content_w' "$CORE" || {
  echo "FAIL no beam feed-forward on armed swap"; exit 1; }
grep -q 'beam_disp_seq' "$CORE" || { echo "FAIL no beam_disp_seq"; exit 1; }
grep -q 'b20_beam_hold' "$CORE" || { echo "FAIL no b20_beam_hold"; exit 1; }
grep -q 'FAULT_B20_NO_BEAM_FEEDFORWARD' "$CORE" || { echo "FAIL no FF red twin"; exit 1; }
grep -q 'FAULT_B20_NO_BEAM_HOLD' "$CORE" || { echo "FAIL no hold red twin"; exit 1; }
# Must not claim closure on live-vs-app alone
grep -q 'beam_disp_seq != app_live_seq' "$CORE" || {
  echo "FAIL hold missing beam-vs-app term"; exit 1; }
echo "OK structure integrated B20 app/beam"

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module b20_integrated_app_beam_tb \
    -Mdir "$mdir" "$@" "$TB" "$BEAM" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"; tail -50 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"
    return 0
  fi
  set +e
  "$mdir/Vb20_integrated_app_beam_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
}

run_one green_ff
GRC=$(cat "$OUT/green_ff/sim.rc")
[[ "$GRC" -eq 0 ]] || { echo "FAIL GREEN_FF rc=$GRC"; exit 1; }
grep -q "OK product feed-forward" "$OUT/green_ff/run.log" || { echo "FAIL ff marker"; exit 1; }
grep -q "PASS b20_integrated_app_beam_tb GREEN feedforward" "$OUT/green_ff/run.log" || {
  echo "FAIL ff pass"; exit 1; }
echo "OK GREEN feed-forward atomic DE+bank frame"

run_one green_hold -DFAULT_B20_NO_BEAM_FEEDFORWARD
HRC=$(cat "$OUT/green_hold/sim.rc")
[[ "$HRC" -eq 0 ]] || { echo "FAIL GREEN_HOLD rc=$HRC"; exit 1; }
grep -q "OK no-feedforward + beam_hold" "$OUT/green_hold/run.log" || {
  echo "FAIL hold marker"; exit 1; }
grep -q "island=0" "$OUT/green_hold/run.log" || { echo "FAIL hold island"; exit 1; }
echo "OK GREEN hold covers lag frame without feed-forward"

run_one red_island -DFAULT_B20_NO_BEAM_FEEDFORWARD -DFAULT_B20_NO_BEAM_HOLD
RRC=$(cat "$OUT/red_island/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED rc=$RRC"; exit 1; }
grep -q "REPRO_OK" "$OUT/red_island/run.log" || { echo "FAIL repro"; exit 1; }
grep -q "island_px=" "$OUT/red_island/run.log" || { echo "FAIL island score"; exit 1; }
echo "OK RED island REPRO (no FF, live-vs-app hold only)"

echo "PASS test_b20_integrated_app_beam true rc=0"
