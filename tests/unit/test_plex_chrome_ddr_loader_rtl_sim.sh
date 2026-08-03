#!/usr/bin/env bash
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: missing marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL $label: compile-only is not a pass" >&2
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
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/plex_chrome_ddr_loader"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

sv=(
  "$ROOT/tests/rtl/plex_chrome_ddr_loader_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv"
  "$ROOT/tests/rtl/plex_chrome_ddr_loader_tb.cpp"
)

echo "=== BUILD plex_chrome_ddr_loader TB ===" >&2
"$RUN_VERILATOR" --cc --exe --build --top-module plex_chrome_ddr_loader_tb \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -CFLAGS "-std=c++17 -O2" --Mdir "$BUILD" "${sv[@]}"

echo "=== RUN ===" >&2
set +e
OUT="$("$BUILD/Vplex_chrome_ddr_loader_tb" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "plex_chrome_ddr_loader_tb rc=$RC"
assert_sim_executed "chrome_ddr" "$OUT" \
  "PASS quiet" "PASS load" "PASS same-seq" "PASS plxo" "PASS bad-magic" \
  "plex_chrome_ddr_loader_tb: PASS"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL rc=$RC" >&2
  exit "$RC"
fi
echo "test_plex_chrome_ddr_loader_rtl_sim: PASS"
exit 0
