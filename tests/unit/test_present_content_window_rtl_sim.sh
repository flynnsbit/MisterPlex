#!/usr/bin/env bash
# Fabric content window — red-before-green Verilator gate.
# A) legacy fixed FRAME map → REPRO quarter-size class (full-320 stretch FAILS)
# B) win_enable 320x240 window → PASS full content stretch across DE
# C) legacy 480p identity → PASS (480 path must keep working)
# Asserts TB EXECUTED. Soft-skip≠PASS. true rc direct.
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
    echo "FAIL $label: compile-only or empty run is not a pass (soft-skip≠PASS)" >&2
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

BUILD="$ROOT/build/verilator/present_content_window"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/present_content_window_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_content_window.sv"
  "$ROOT/tests/rtl/present_content_window_tb.cpp"
)
vflags=(--cc --exe --build --top-module present_content_window_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD present_content_window TB ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD" "${common_sv[@]}"

echo "=== A) LEGACY fixed map (expect REPRO_OK quarter_class) ===" >&2
set +e
LEGACY_OUT="$(WINDOW_MODE=legacy "$BUILD/Vpresent_content_window_tb" 2>&1)"
LEGACY_RC=$?
set -e
printf '%s\n' "$LEGACY_OUT"
echo "legacy true rc=$LEGACY_RC"

echo "=== B) WINDOW 320x240 (expect PASS full stretch) ===" >&2
set +e
WINDOW_OUT="$(WINDOW_MODE=window "$BUILD/Vpresent_content_window_tb" 2>&1)"
WINDOW_RC=$?
set -e
printf '%s\n' "$WINDOW_OUT"
echo "window true rc=$WINDOW_RC"

echo "=== C) LEGACY 480p identity (expect PASS) ===" >&2
set +e
L480_OUT="$(WINDOW_MODE=legacy480 "$BUILD/Vpresent_content_window_tb" 2>&1)"
L480_RC=$?
set -e
printf '%s\n' "$L480_OUT"
echo "legacy480 true rc=$L480_RC"

assert_sim_executed "legacy" "$LEGACY_OUT" \
  "REPRO_OK legacy_fixed_map" "quarter_class=1" "PASS race model legacy"
assert_sim_executed "window" "$WINDOW_OUT" \
  "PASS present_content_window_320" "PASS race model window"
assert_sim_executed "legacy480" "$L480_OUT" \
  "PASS legacy_480p_identity"

if [[ "$LEGACY_RC" -ne 0 ]]; then
  echo "FAIL: legacy quarter-class repro did not return rc=0" >&2
  exit 1
fi
if [[ "$WINDOW_RC" -ne 0 ]]; then
  echo "FAIL: window 320 stretch did not PASS" >&2
  exit 1
fi
if [[ "$L480_RC" -ne 0 ]]; then
  echo "FAIL: legacy 480p identity broken" >&2
  exit 1
fi

# Cross-check: window must NOT print quarter_class success markers as its pass.
if grep -q 'quarter_class=1' <<<"$WINDOW_OUT"; then
  echo "FAIL: window mode must not be quarter-class" >&2
  exit 1
fi

echo "OK present_content_window_rtl_sim: REPRO legacy quarter + PASS window 320 + PASS legacy480"
exit 0
