#!/usr/bin/env bash
# present_geom_latch RBG — reset safe, PLXG accept, PLXW reject, seq update.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e
"$RUN" --version >/dev/null 2>&1
VRC=$?
set -e
if [[ "$VRC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  echo "RTL SIM ERROR: Verilator not found" >&2; exit 3
fi
BUILD="$ROOT/build/verilator/present_geom_latch"
mkdir -p "$BUILD"
set +e
"$RUN" -cc --exe --build -j 4 --top-module present_geom_latch_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -Mdir "$BUILD" \
  "$ROOT/tests/rtl/present_geom_latch_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_geom_latch.sv" \
  "$ROOT/tests/rtl/present_geom_latch_tb.cpp" >"$BUILD/build.log" 2>&1
BRC=$?
set -e
if [[ "$BRC" -ne 0 ]]; then tail -30 "$BUILD/build.log" >&2; exit "$BRC"; fi
set +e
OUT="$("$BUILD/Vpresent_geom_latch_tb" 2>&1)"
RC=$?
set -e
echo "$OUT"
for m in "CASE reset_safe EXECUTED" "PASS reset_safe" "CASE plxg_720 EXECUTED" "PASS plxg_720" \
         "CASE neg_plxw_magic EXECUTED" "PASS neg_plxw_magic" "PASS plxg_seq3" "PLXG_LATCH_DONE"; do
  grep -q -- "$m" <<<"$OUT" || { echo "FAIL missing marker: $m" >&2; exit 2; }
done
if [[ "$RC" -ne 0 ]]; then echo "FAIL true rc=$RC" >&2; exit "$RC"; fi
echo "OK present_geom_latch_rtl_sim true rc=0"
exit 0
