#!/usr/bin/env bash
# Verilator gate for present_pace_seq (fab-pace).
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
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/present_pace"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

sv=(
  "$ROOT/tests/rtl/present_pace_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_pace_seq.sv"
  "$ROOT/tests/rtl/present_pace_tb.cpp"
)
vflags=(--cc --exe --build --top-module present_pace_tb
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD present_pace TB ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD" "${sv[@]}"

echo "=== RUN PACE_CASE=all ===" >&2
set +e
OUT="$("$BUILD/Vpresent_pace_tb" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "present_pace_tb rc=$RC"
assert_sim_executed "present_pace" "$OUT" \
  "PASS legacy" "PASS late" "PASS early" "PASS film" "PASS tear-guard" \
  "present_pace_tb: PASS"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL present_pace_tb rc=$RC" >&2
  exit "$RC"
fi
echo "test_present_pace_rtl_sim: PASS"
exit 0
