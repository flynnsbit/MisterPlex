#!/usr/bin/env bash
# RTL oracle: timing_960 fps_milli + beam 1182×564 DE/sync (rd-duck overflow + raster).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/present_beam_960_oracle"
mkdir -p "$OUT"
rm -rf "$OUT/run"
echo "RTL SIM: $($RV --version 2>&1 | head -1)"
"$RV" -Wno-fatal --binary --timing --top-module present_beam_960_oracle_tb \
  -Mdir "$OUT/run" \
  "$ROOT/tests/rtl/present_beam_960_oracle_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
set +e
"$OUT/run/Vpresent_beam_960_oracle_tb" >"$OUT/run.log" 2>&1
rc=$?
set -e
cat "$OUT/run.log"
if [[ $rc -ne 0 ]]; then echo "FAIL oracle rc=$rc"; exit 1; fi
grep -q "PASS present_beam_960_oracle" "$OUT/run.log" || { echo "FAIL no PASS"; exit 1; }
grep -q "fps_milli=30000" "$OUT/run.log" || { echo "FAIL fps not 30000"; exit 1; }
grep -q "true_de=1" "$OUT/run.log" || { echo "FAIL true_de"; exit 1; }
echo "PASS test_present_beam_960_oracle true rc=$rc"
exit 0
