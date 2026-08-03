#!/usr/bin/env bash
# B15 exact frame counts @20 MHz for content_fps 24 vs 30 + RED ignore-fps.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/b15_cadence_framecount"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
TB="$ROOT/tests/rtl/b15_cadence_framecount_tb.sv"
mkdir -p "$OUT"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"

# Arithmetic pre-register (awk; no bc)
awk 'BEGIN{
  H=1182; V24=705; V30=564; W=4*H*V24;
  f24=W/(H*V24); f30=W/(H*V30);
  printf("PREREG window_clks=%d frames24=%.0f frames30=%.0f\n", W, f24, f30);
  if (f24!=4 || f30!=5) { print "FAIL prereg arithmetic"; exit 1 }
}'

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module b15_cadence_framecount_tb \
    -Mdir "$mdir" "$@" "$TB" "$BEAM" >"$mdir/build.log" 2>&1
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
grep -q "OK B15 fps=24 frames=4 exact" "$OUT/green/run.log" || { echo "FAIL 24"; exit 1; }
grep -q "OK B15 fps=30 frames=5 exact" "$OUT/green/run.log" || { echo "FAIL 30"; exit 1; }
grep -q "PASS b15_cadence_framecount GREEN" "$OUT/green/run.log" || { echo "FAIL pass"; exit 1; }
echo "OK GREEN framecounts"

run_one red_ignore -DFAULT_B15_IGNORE_FPS
RRC=$(cat "$OUT/red_ignore/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED rc=$RRC"; exit 1; }
grep -q "OK RED ignore-fps broke count" "$OUT/red_ignore/run.log" || { echo "FAIL red marker"; exit 1; }
echo "OK RED FAULT_B15_IGNORE_FPS"

# Product source: must NOT hardwire 24 outside FAULT
if grep -n "content_fps = 8'd24" "$ROOT/fpga/Plex_MiSTer/Plex.sv" | grep -v FAULT_B15; then
  # Allow only inside FAULT ifdef block — check preceding context
  :
fi
# Stronger: product path idle default 30 under comment B15
grep -q "B15: content_fps is RUNTIME" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  || { echo "FAIL Plex missing B15 banner"; exit 1; }
grep -q "content_fps_idle" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
  || { echo "FAIL Plex missing idle/runtime mux"; exit 1; }
# Hardwire 24 only under FAULT
if grep -n "wire \[7:0\] content_fps = 8'd24" "$ROOT/fpga/Plex_MiSTer/Plex.sv"; then
  grep -B2 "wire \[7:0\] content_fps = 8'd24" "$ROOT/fpga/Plex_MiSTer/Plex.sv" \
    | grep -q "FAULT_B15_FPS_HARDWIRE_24" \
    || { echo "FAIL content_fps hardwired 24 outside FAULT"; exit 1; }
fi
echo "OK Plex B15 runtime source shape"

echo "PASS test_b15_cadence_framecount true rc=0"
exit 0
