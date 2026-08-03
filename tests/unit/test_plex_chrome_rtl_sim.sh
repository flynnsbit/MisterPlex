#!/usr/bin/env bash
# Verilator sim gate for plex_chrome product plane.
# Red-before-green cases: passthrough / glyph / idle.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: sim did not EXECUTE expected marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL $label: compile-only or empty run is not a pass" >&2
    exit 2
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/plex_chrome"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

sv=(
  "$ROOT/tests/rtl/plex_chrome_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv"
  "$ROOT/tests/rtl/plex_chrome_tb.cpp"
)
vflags=(--cc --exe --build --top-module plex_chrome_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD plex_chrome TB ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD" "${sv[@]}"

echo "=== RUN CHROME_CASE=all ===" >&2
set +e
OUT="$("$BUILD/Vplex_chrome_tb" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "plex_chrome_tb rc=$RC"
assert_sim_executed "plex_chrome" "$OUT" "PASS passthrough" "PASS glyph" "PASS idle" "plex_chrome_tb: PASS"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL plex_chrome_tb rc=$RC" >&2
  exit "$RC"
fi
echo "test_plex_chrome_rtl_sim: PASS"
exit 0
