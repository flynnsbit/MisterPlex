#!/usr/bin/env bash
# PLXG q3 display_w/h through plex_present_geom_mux (624/618 oracle).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e
VER="$($RUN --version 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  echo "RTL SIM ERROR: Verilator not found" >&2; exit 3
elif [[ "$RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2; exit "$RC"
fi

GOOD="$ROOT/build/verilator/plex_mux_disp_good"
FAULT="$ROOT/build/verilator/plex_mux_disp_fault"
rm -rf "$GOOD" "$FAULT"
mkdir -p "$GOOD" "$FAULT"

sv=(
  "$ROOT/tests/rtl/plex_mux_display_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_present_geom_mux.sv"
  "$ROOT/tests/rtl/plex_mux_display_tb.cpp"
)
vf=(--cc --exe --build --top-module plex_mux_display_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
  -CFLAGS "-std=c++17 -O2")

echo "=== A) PRODUCT mux display 624/618 ===" >&2
"$RUN" "${vf[@]}" --Mdir "$GOOD" "${sv[@]}"
set +e
OUT="$("$GOOD/Vplex_mux_display_tb" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "product true rc=$RC"
grep -q "OK plex_mux_display 624/618" <<<"$OUT"
grep -q "MEASURED mux624/618" <<<"$OUT"
grep -q "OK plex_mux_display 432/426" <<<"$OUT"
grep -q "MEASURED mux432/426" <<<"$OUT"
[[ "$RC" -eq 0 ]] || { echo "FAIL product rc=$RC" >&2; exit "$RC"; }

echo "=== B) FAULT_MUX_DISPLAY_EQ_CODED (expect display=624 REPRO) ===" >&2
"$RUN" "${vf[@]}" --Mdir "$FAULT" -DFAULT_MUX_DISPLAY_EQ_CODED "${sv[@]}"
set +e
FOUT="$("$FAULT/Vplex_mux_display_tb" 2>&1)"; FRC=$?
set -e
printf '%s\n' "$FOUT"
echo "fault true rc=$FRC"
[[ "$FRC" -ne 0 ]] || { echo "FAIL fault twin must not pass" >&2; exit 1; }
grep -q "FAIL display_w expected 618" <<<"$FOUT" || {
  echo "FAIL expected coded-alias REPRO" >&2; printf '%s\n' "$FOUT" >&2; exit 1
}
echo "REPRO_OK FAULT_MUX_DISPLAY_EQ_CODED display=coded"

echo "OK test_plex_mux_display"
exit 0
