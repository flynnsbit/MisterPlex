#!/usr/bin/env bash
# B15 ABI#2: q5 fps_valid/content_fps → exact unique frame counts + RED ignore valid.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/b15_cadence_framecount"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
SEL="$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv"
TB="$ROOT/tests/rtl/b15_cadence_framecount_tb.sv"
mkdir -p "$OUT"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"

awk 'BEGIN{
  H=1182; V24=705; V30=564; W=4*H*V24;
  printf("PREREG window_clks=%d frames24=%.0f frames30=%.0f\n", W, W/(H*V24), W/(H*V30));
  if (W/(H*V24)!=4 || W/(H*V30)!=5) { print "FAIL prereg"; exit 1 }
}'

# Source shape: consumer module + no idle-30 invent
grep -q "plex_content_fps_sel" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  || { echo "FAIL Plex missing fps_sel"; exit 1; }
grep -q "fps_valid" "$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv" \
  || { echo "FAIL sel missing fps_valid"; exit 1; }
if grep -n "content_fps_idle.*=.*8'd30" "$ROOT/fpga/Plex_MiSTer/Plex.sv"; then
  echo "FAIL invent idle-30 still present"; exit 1
fi
grep -q "doorbell+0x828\|q5" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  || grep -q "0x828\|q5" "$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv" \
  || { echo "FAIL missing q5 ABI cite"; exit 1; }
# Hardwire 24 only under FAULT
if grep -n "wire \[7:0\] content_fps = 8'd24" "$ROOT/fpga/Plex_MiSTer/Plex.sv"; then
  grep -B3 "wire \[7:0\] content_fps = 8'd24" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
    | grep -q "FAULT_B15_FPS_HARDWIRE_24" \
    || { echo "FAIL hardwire 24 outside FAULT"; exit 1; }
fi
echo "OK Plex/sel ABI#2 source shape"

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module b15_cadence_framecount_tb \
    -Mdir "$mdir" "$@" "$TB" "$BEAM" "$SEL" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"; tail -40 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"; return 0
  fi
  set +e
  "$mdir/Vb15_cadence_framecount_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
}

run_one green
GRC=$(cat "$OUT/green/sim.rc")
[[ "$GRC" -eq 0 ]] || { echo "FAIL GREEN rc=$GRC"; exit 1; }
grep -q "OK B15 fps_valid=1 fps=24 frames=4 exact" "$OUT/green/run.log" || { echo "FAIL 24"; exit 1; }
grep -q "OK B15 fps_valid=1 fps=30 frames=5 exact" "$OUT/green/run.log" || { echo "FAIL 30"; exit 1; }
grep -q "OK B15 fps_valid=0 does not invent 30" "$OUT/green/run.log" || { echo "FAIL valid0"; exit 1; }
grep -q "PASS b15_cadence_framecount GREEN" "$OUT/green/run.log" || { echo "FAIL pass"; exit 1; }
echo "OK GREEN q5 framecounts"

run_one red_ignore -DFAULT_B15_IGNORE_FPS_VALID
RRC=$(cat "$OUT/red_ignore/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED rc=$RRC"; exit 1; }
grep -q "OK RED fps_valid ignored/broken frames=4" "$OUT/red_ignore/run.log" \
  || { echo "FAIL red marker"; exit 1; }
echo "OK RED FAULT_B15_IGNORE_FPS_VALID (30 title → 24 unique frames)"

echo "PASS test_b15_cadence_framecount true rc=0"
exit 0
