#!/usr/bin/env bash
# RTL oracle: exact whole-frame DE accounting (fixed + V705 + runtime geom ladder).
# GREEN: equality pix == W*H*frames and line_acc == W..W for 320/640/960.
# RED:  FAULT_DROP_ONE_PER_LINE must fail those equalities (not a soft lower-bound).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/present_beam_960_oracle"
RTL_TB="$ROOT/tests/rtl/present_beam_960_oracle_tb.sv"
RTL_T="$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv"
RTL_B="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
mkdir -p "$OUT"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"

# Writes sim rc to $1_RC file so set -e never swallows red-twin non-zero.
build_run() {
  local tag="$1"; shift
  local mdir="$OUT/$tag"
  rm -rf "$mdir"
  mkdir -p "$mdir"
  set +e
  "$RV" -Wno-fatal --binary --timing --top-module present_beam_960_oracle_tb \
    -Mdir "$mdir" "$@" \
    "$RTL_TB" "$RTL_T" "$RTL_B" >"$mdir/build.log" 2>&1
  local brc=$?
  set -e
  if [[ "$brc" -ne 0 ]]; then
    echo "FAIL $tag build rc=$brc"
    tail -40 "$mdir/build.log"
    echo "$brc" >"$mdir/sim.rc"
    return 0
  fi
  set +e
  "$mdir/Vpresent_beam_960_oracle_tb" >"$mdir/run.log" 2>&1
  local rrc=$?
  set -e
  echo "$rrc" >"$mdir/sim.rc"
  cat "$mdir/run.log"
  echo "true rc=$rrc tag=$tag"
  return 0
}

# ----- GREEN -----
build_run green
GRC="$(cat "$OUT/green/sim.rc")"
if [[ "$GRC" -ne 0 ]]; then
  echo "FAIL oracle GREEN rc=$GRC"
  exit 1
fi
grep -q "PASS present_beam_960_oracle" "$OUT/green/run.log" || { echo "FAIL no PASS"; exit 1; }
grep -q "fps_milli=30000" "$OUT/green/run.log" || { echo "FAIL fps not 30000"; exit 1; }
grep -q "true_de=1" "$OUT/green/run.log" || { echo "FAIL true_de"; exit 1; }
grep -q "OK FIXED_960x540 exact" "$OUT/green/run.log" || { echo "FAIL fixed exact"; exit 1; }
grep -q "OK V705_960x540 exact" "$OUT/green/run.log" || { echo "FAIL v705 exact"; exit 1; }
grep -q "OK RTGEOM_320x240 exact" "$OUT/green/run.log" || { echo "FAIL rt 320 exact"; exit 1; }
grep -q "OK RTGEOM_640x360 exact" "$OUT/green/run.log" || { echo "FAIL rt 640 exact"; exit 1; }
grep -q "OK RTGEOM_960x540 exact" "$OUT/green/run.log" || { echo "FAIL rt 960 exact"; exit 1; }
grep -q "OK FIXED_960x540 exact pix=1036800" "$OUT/green/run.log" \
  || { echo "FAIL fixed pix equality marker"; exit 1; }
grep -q "line_acc=320..320" "$OUT/green/run.log" || { echo "FAIL line_acc 320"; exit 1; }
grep -q "line_acc=640..640" "$OUT/green/run.log" || { echo "FAIL line_acc 640"; exit 1; }
grep -q "line_acc=960..960" "$OUT/green/run.log" || { echo "FAIL line_acc 960"; exit 1; }
echo "OK oracle GREEN rc=0"

# ----- RED twin: drop-one-per-line must be caught -----
build_run red -DFAULT_DROP_ONE_PER_LINE
RRC="$(cat "$OUT/red/sim.rc")"
if [[ "$RRC" -eq 0 ]]; then
  echo "FAIL RED_TWIN: expected non-zero rc (exact checks should catch drop)"
  exit 1
fi
if ! grep -qE "FAIL .*line_acc=|FAIL .*pix=|drop/dup class" "$OUT/red/run.log"; then
  echo "FAIL RED_TWIN: rc=$RRC but no exact-fail marker"
  tail -30 "$OUT/red/run.log"
  exit 1
fi
echo "OK oracle RED_TWIN rc=$RRC (caught drop-one-per-line)"
echo "PASS test_present_beam_960_oracle true rc=0"
exit 0
