#!/usr/bin/env bash
# E2E: DDR PLXC → host_if → plex_chrome pixels (fab route B proof).
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: missing $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL $label: compile-only is not a pass" >&2
    exit 2
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e
VER="$($RUN --version 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && { echo "SKIP" >&2; exit 77; }
  echo "Verilator missing" >&2; exit 3
elif [[ "$RC" -ne 0 ]]; then
  exit "$RC"
fi

BUILD="$ROOT/build/verilator/plex_chrome_e2e"
mkdir -p "$BUILD"
echo "RTL SIM: $VER" >&2

"$RUN" --cc --exe --build --top-module plex_chrome_e2e_tb \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -CFLAGS "-std=c++17 -O2" --Mdir "$BUILD" \
  "$ROOT/tests/rtl/plex_chrome_e2e_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv" \
  "$ROOT/tests/rtl/plex_chrome_e2e_tb.cpp"

set +e
OUT="$("$BUILD/Vplex_chrome_e2e_tb" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "plex_chrome_e2e_tb rc=$RC"
assert_sim_executed "e2e" "$OUT" \
  "PASS pre-load cfg off" "PASS load-applied" "PASS glyph-pixels" "PASS plxo" "PASS idle" \
  "plex_chrome_e2e_tb: PASS"
[[ "$RC" -eq 0 ]] || exit "$RC"
echo "test_plex_chrome_e2e_rtl_sim: PASS"
exit 0
