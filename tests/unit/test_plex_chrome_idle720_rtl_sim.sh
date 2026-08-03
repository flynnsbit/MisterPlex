#!/usr/bin/env bash
# Native 1280×720 fabric idle — red-before-green.
# RED: FAULT_480P_GEOM=1 must fail 720p mon probe (or pass only as "fault engaged").
# GREEN: exact chevron geometry + vsync phase + subsample no video leak.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || { echo "FAIL $label compile-only" >&2; exit 2; }
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e
VER="$($RUN --version 2>&1)"; RC=$?
set -e
if [[ "$RC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  exit "$RC"
fi

SV=(
  "$ROOT/tests/rtl/plex_chrome_idle720_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv"
  "$ROOT/tests/rtl/plex_chrome_idle720_tb.cpp"
)
VFLAGS=(--cc --exe --build --top-module plex_chrome_idle720_tb
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SELRANGE
  -CFLAGS "-std=c++17 -O2")

# --- RED: 480p-clamped geometry must NOT look like 720p ---
BUILD_RED="$ROOT/build/verilator/plex_chrome_idle720_red"
mkdir -p "$BUILD_RED"
echo "=== BUILD idle720 RED (FAULT_480P_GEOM=1) ===" >&2
"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=1 --Mdir "$BUILD_RED" "${SV[@]}"

echo "=== RUN idle720 RED ===" >&2
set +e
OUT_RED="$(IDLE720_MODE=red "$BUILD_RED/Vplex_chrome_idle720_tb" 2>&1)"
RC_RED=$?
set -e
printf '%s\n' "$OUT_RED"
echo "idle720_red true rc=$RC_RED"
assert_sim_executed "idle720-red" "$OUT_RED" "PASS idle720-red-mon" "plex_chrome_idle720_tb: PASS (red fault engaged)"
[[ "$RC_RED" -eq 0 ]] || { echo "FAIL red rc=$RC_RED" >&2; exit "$RC_RED"; }

# --- GREEN: full 720p idle ---
BUILD_G="$ROOT/build/verilator/plex_chrome_idle720"
mkdir -p "$BUILD_G"
echo "=== BUILD idle720 GREEN ===" >&2
"$RUN" "${VFLAGS[@]}" -GFAULT_480P_GEOM=0 --Mdir "$BUILD_G" "${SV[@]}"

echo "=== RUN idle720 GREEN ===" >&2
set +e
OUT_G="$("$BUILD_G/Vplex_chrome_idle720_tb" 2>&1)"
RC_G=$?
set -e
printf '%s\n' "$OUT_G"
echo "idle720_green true rc=$RC_G"
assert_sim_executed "idle720-green" "$OUT_G" \
  "PASS idle720-geom" "PASS idle720-phase" "PASS idle720-screensaver-motion" \
  "PASS idle720-subsample" "plex_chrome_idle720_tb: PASS"
[[ "$RC_G" -eq 0 ]] || { echo "FAIL green rc=$RC_G" >&2; exit "$RC_G"; }

echo "test_plex_chrome_idle720_rtl_sim: PASS"
exit 0
