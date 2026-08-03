#!/usr/bin/env bash
# B20: beam DE hold until store pending_ready (delayed ready past one fstart).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OUT="$ROOT/build/verilator/b20_beam_de_hold"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
STORE="$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
TB="$ROOT/tests/rtl/b20_beam_de_hold_tb.sv"
mkdir -p "$OUT"

echo "RTL SIM: $($RV --version 2>&1 | head -1)"

# Structural: beam gate + core formula + store export
grep -q 'rt_de_apply' "$BEAM" || { echo "FAIL beam missing rt_de_apply"; exit 1; }
grep -q 'FAULT_B20_BEAM_FREE_RUN' "$BEAM" || { echo "FAIL no red twin"; exit 1; }
grep -q 'beam_de_apply' "$CORE" || { echo "FAIL core missing beam_de_apply"; exit 1; }
grep -q 'swap_pending && store_pending_ready' "$CORE" || { echo "FAIL no swap_fire"; exit 1; }
grep -q 'pending_ready' "$STORE" || { echo "FAIL store no pending_ready export"; exit 1; }
grep -q 'assign pending_ready = pending_ready_s2' "$STORE" || { echo "FAIL assign"; exit 1; }
# Must not free-run DE when live pending without ready
if grep -n 'rt_de_apply(1'\''b1)' "$CORE" | grep -v beam_de; then
  echo "FAIL core hardwires apply=1 on product beam"; exit 1
fi
echo "OK structure B20 beam/store coupling"

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module b20_beam_de_hold_tb \
    -Mdir "$mdir" "$@" "$TB" "$BEAM" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"; tail -40 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"; return 0
  fi
  set +e
  "$mdir/Vb20_beam_de_hold_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
}

run_one green
GRC=$(cat "$OUT/green/sim.rc")
[[ "$GRC" -eq 0 ]] || { echo "FAIL GREEN rc=$GRC"; exit 1; }
grep -q "OK hold OLD DE" "$OUT/green/run.log" || { echo "FAIL hold marker"; exit 1; }
grep -q "OK swap_fire applied NEW DE" "$OUT/green/run.log" || { echo "FAIL apply"; exit 1; }
grep -q "PASS b20_beam_de_hold_tb GREEN" "$OUT/green/run.log" || { echo "FAIL pass"; exit 1; }
echo "OK GREEN delayed pending_ready hold"

run_one red_free -DFAULT_B20_BEAM_FREE_RUN
RRC=$(cat "$OUT/red_free/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED rc=$RRC"; exit 1; }
grep -q "REPRO_OK" "$OUT/red_free/run.log" || { echo "FAIL repro"; exit 1; }
grep -q "pending_ready=0" "$OUT/red_free/run.log" || { echo "FAIL red context"; exit 1; }
echo "OK RED free-run REPRO (island class)"

echo "PASS test_b20_beam_de_hold true rc=0"
