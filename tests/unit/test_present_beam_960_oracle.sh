#!/usr/bin/env bash
# Exact whole-frame DE oracle + B13 runtime ladder + per-geometry red twin.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/present_beam_960_oracle"
mkdir -p "$OUT"
rm -rf "$OUT/run"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"

# B13 structural (product path)
if ! grep -q "use_rt_geom(1'b1)" "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"; then
  echo "FAIL B13: present_core use_rt_geom not ON"
  exit 1
fi
if ! grep -q "content_w" "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"; then
  echo "FAIL B13: content_w port missing"
  exit 1
fi

set +e
"$RV" -Wno-fatal --binary --timing --top-module present_beam_960_oracle_tb \
  -Mdir "$OUT/run" \
  "$ROOT/tests/rtl/present_beam_960_oracle_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv" >"$OUT/build.log" 2>&1
BRC=$?
set -e
if [[ "$BRC" -ne 0 ]]; then
  echo "FAIL oracle build rc=$BRC"
  tail -40 "$OUT/build.log"
  exit 1
fi
set +e
"$OUT/run/Vpresent_beam_960_oracle_tb" >"$OUT/run.log" 2>&1
RC=$?
set -e
cat "$OUT/run.log"
echo "true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL oracle sim rc=$RC"
  exit 1
fi
grep -q "PASS present_beam_960_oracle" "$OUT/run.log" || { echo "FAIL no PASS"; exit 1; }
grep -q "fps_milli=30000" "$OUT/run.log" || { echo "FAIL fps"; exit 1; }
grep -q "OK FIXED_960x540 exact" "$OUT/run.log" || { echo "FAIL fixed"; exit 1; }
grep -q "OK V705_960x540 exact" "$OUT/run.log" || { echo "FAIL v705"; exit 1; }
grep -q "OK RTGEOM_320x240 exact" "$OUT/run.log" || { echo "FAIL 320"; exit 1; }
grep -q "OK RTGEOM_416x234 exact" "$OUT/run.log" || { echo "FAIL 416"; exit 1; }
grep -q "line_acc=416..416" "$OUT/run.log" || { echo "FAIL line 416"; exit 1; }
grep -q "OK RTGEOM_624x480 exact" "$OUT/run.log" || { echo "FAIL 624"; exit 1; }
grep -q "OK RTGEOM_640x360 exact" "$OUT/run.log" || { echo "FAIL 640"; exit 1; }
grep -q "OK RTGEOM_960x540 exact" "$OUT/run.log" || { echo "FAIL 960"; exit 1; }
grep -q "line_acc=624..624" "$OUT/run.log" || { echo "FAIL line 624"; exit 1; }
grep -q "OK RED RTGEOM_320x240 caught" "$OUT/run.log" || { echo "FAIL red 320"; exit 1; }
grep -q "OK RED RTGEOM_416x234 caught" "$OUT/run.log" || { echo "FAIL red 416"; exit 1; }
grep -q "OK RED RTGEOM_624x480 caught" "$OUT/run.log" || { echo "FAIL red 624"; exit 1; }
grep -q "OK RED RTGEOM_640x360 caught" "$OUT/run.log" || { echo "FAIL red 640"; exit 1; }
grep -q "OK RED RTGEOM_960x540 caught" "$OUT/run.log" || { echo "FAIL red 960"; exit 1; }
grep -q "STA_ACK V705" "$OUT/run.log" || { echo "FAIL sta ack"; exit 1; }
grep -q "b13_rtgeom_exact=1" "$OUT/run.log" || { echo "FAIL b13 marker"; exit 1; }
echo "PASS test_present_beam_960_oracle true rc=0"
exit 0
