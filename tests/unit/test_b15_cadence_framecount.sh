#!/usr/bin/env bash
# B15 ABI#2: q5 fps → raster + cadence; 24/30 1:1; 25 is 25/30 (not 1:1); honest claims.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/b15_cadence_framecount"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
SEL="$ROOT/fpga/Plex_MiSTer/rtl/plex_content_fps_sel.sv"
CAD="$ROOT/fpga/Plex_MiSTer/rtl/present_cadence.sv"
TB="$ROOT/tests/rtl/b15_cadence_framecount_tb.sv"
mkdir -p "$OUT"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"

# Product threshold: film <=24 only (not <=25)
grep -q "content_fps <= 8'd24" "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" \
  || { echo "FAIL present_core missing fps<=24 film threshold"; exit 1; }
if grep -n "content_fps <= 8'd25" "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"; then
  echo "FAIL present_core still uses <=25 film threshold"; exit 1
fi
# BEAM_960 cadence uses core Hz not bare display_hz
grep -q "cadence_display_hz" "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" \
  || { echo "FAIL missing cadence_display_hz"; exit 1; }
echo "OK present_core film<=24 + cadence_display_hz"

awk 'BEGIN{
  H=1182; V24=705; V30=564; W=4*H*V24;
  printf("PREREG window_clks=%d raster24=%.0f raster30=%.0f\n", W, W/(H*V24), W/(H*V30));
}'

run_one() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"; mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module b15_cadence_framecount_tb \
    -Mdir "$mdir" "$@" "$TB" "$BEAM" "$SEL" "$CAD" >"$mdir/build.log" 2>&1
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
grep -q "OK fps=25 -> TV class V=564" "$OUT/green/run.log" || { echo "FAIL 25"; exit 1; }
grep -q "OK B15 raster frame_start=4" "$OUT/green/run.log" || { echo "FAIL r24"; exit 1; }
grep -q "OK B15 raster frame_start=5" "$OUT/green/run.log" || { echo "FAIL r30"; exit 1; }
grep -q "OK ADV_PROOF integer 1:1 raster=5 advances=5" "$OUT/green/run.log" \
  || { echo "FAIL adv30"; exit 1; }
grep -q "OK B15 fps=25 raster frame_start=5 advances=4" "$OUT/green/run.log" \
  || { echo "FAIL adv25 short"; exit 1; }
grep -q "OK B15 fps=25 LONG 30-raster advances=25" "$OUT/green/run.log" \
  || { echo "FAIL adv25 long 6:5"; exit 1; }
grep -q "not unique-bank claim" "$OUT/green/run.log" || { echo "FAIL honesty"; exit 1; }
grep -q "content!=core" "$OUT/green/run.log" || { echo "FAIL 25 equals core claim"; exit 1; }
echo "OK GREEN"

run_one red_ignore -DFAULT_B15_IGNORE_FPS_VALID
RRC=$(cat "$OUT/red_ignore/sim.rc")
[[ "$RRC" -eq 0 ]] || { echo "FAIL RED ignore rc=$RRC"; exit 1; }
grep -q "OK RED raster broken" "$OUT/red_ignore/run.log" || { echo "FAIL red ign"; exit 1; }
echo "OK RED IGNORE_FPS_VALID"

run_one red_hdmi60 -DFAULT_B15_CADENCE_HDMI60
R60=$(cat "$OUT/red_hdmi60/sim.rc")
[[ "$R60" -eq 0 ]] || { echo "FAIL RED hdmi60 rc=$R60"; exit 1; }
grep -q "OK RED CADENCE_HDMI60" "$OUT/red_hdmi60/run.log" || { echo "FAIL red60"; exit 1; }
echo "OK RED CADENCE_HDMI60"

echo "PASS test_b15_cadence_framecount true rc=0"
exit 0
