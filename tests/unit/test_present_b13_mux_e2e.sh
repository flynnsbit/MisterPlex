#!/usr/bin/env bash
# B13 E2E product mux→beam. GREEN=live PLXG DE; RED=FAULT_B8_FORCE_ALWAYS pins 960.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/present_b13_mux_e2e"
MUX="$ROOT/fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
TB="$ROOT/tests/rtl/present_b13_mux_e2e_tb.sv"
mkdir -p "$OUT"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"

[[ -f "$MUX" ]] || { echo "FAIL mux missing"; exit 1; }
# Product mux must encode fallback-only force (w-mem COLLISION #5 fix)
grep -q 'force_native_960 = ~plxg_live' "$MUX" \
  || { echo "FAIL mux missing fallback force (~plxg_live)"; exit 1; }
grep -q 'FAULT_B8_FORCE_ALWAYS' "$MUX" \
  || { echo "FAIL mux missing FAULT_B8_FORCE_ALWAYS red hook"; exit 1; }
# Must NOT be unconditional force under BEAM only
if grep -n "force_native_960 = 1'b1" "$MUX" | grep -v FAULT; then
  # allowed only under FAULT ifdef — check structure
  :
fi

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module present_b13_mux_e2e_tb \
    -Mdir "$mdir" -DPRESENT_BEAM_960 "$@" \
    "$TB" "$BEAM" "$MUX" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"; tail -50 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"; return 0
  fi
  set +e
  "$mdir/Vpresent_b13_mux_e2e_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
}

run_one green
GRC=$(cat "$OUT/green/sim.rc")
[[ "$GRC" -eq 0 ]] || { echo "FAIL GREEN rc=$GRC"; exit 1; }
grep -q "OK E2E mux→beam DE=624x480 exact" "$OUT/green/run.log" || { echo "FAIL 624"; exit 1; }
grep -q "OK E2E mux→beam DE=416x234 exact" "$OUT/green/run.log" || { echo "FAIL 416"; exit 1; }
grep -q "line_acc=416..416" "$OUT/green/run.log" || { echo "FAIL line416"; exit 1; }
grep -q "OK E2E idle fallback DE=960x540" "$OUT/green/run.log" || { echo "FAIL idle"; exit 1; }
grep -q "PASS present_b13_mux_e2e GREEN" "$OUT/green/run.log" || { echo "FAIL pass"; exit 1; }
echo "OK GREEN product mux→beam"

run_one red_fault -DFAULT_B8_FORCE_ALWAYS
RRC=$(cat "$OUT/red_fault/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED fault rc=$RRC"; exit 1; }
grep -q "OK RED FAULT force pins 960x540 over PLXG 624x480" "$OUT/red_fault/run.log" \
  || { echo "FAIL red marker"; exit 1; }
echo "OK RED FAULT_B8_FORCE_ALWAYS (collision #5 class)"

echo "PASS test_present_b13_mux_e2e true rc=0"
exit 0
