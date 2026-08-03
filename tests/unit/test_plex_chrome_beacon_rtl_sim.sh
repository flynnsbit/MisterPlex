#!/usr/bin/env bash
# Red-before-green: PLEX_FAB_PLAY_BEACON lime toggle.
set -euo pipefail
assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: missing marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then exit 2; fi
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then exit "$VERILATOR_RC"; fi

BUILD_R="$ROOT/build/verilator/plex_chrome_beacon_red"
BUILD_G="$ROOT/build/verilator/plex_chrome_beacon"
mkdir -p "$BUILD_R" "$BUILD_G"
sv=(
  "$ROOT/tests/rtl/plex_chrome_beacon_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv"
  "$ROOT/tests/rtl/plex_chrome_beacon_tb.cpp"
)
vflags=(--cc --exe --build --top-module plex_chrome_beacon_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD beacon RED ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD_R" "${sv[@]}"
set +e
OUT_R="$(FAULT_NO_BEACON=1 "$BUILD_R/Vplex_chrome_beacon_tb" 2>&1)"
RC_R=$?
set -e
printf '%s\n' "$OUT_R"
echo "beacon_red true rc=$RC_R"
assert_sim_executed "beacon_red" "$OUT_R" "PASS beacon-red-off" "plex_chrome_beacon_tb: PASS"
[[ "$RC_R" -eq 0 ]] || exit "$RC_R"

echo "=== BUILD beacon GREEN ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD_G" "${sv[@]}"
set +e
OUT_G="$("$BUILD_G/Vplex_chrome_beacon_tb" 2>&1)"
RC_G=$?
set -e
printf '%s\n' "$OUT_G"
echo "beacon_green true rc=$RC_G"
assert_sim_executed "beacon_green" "$OUT_G" \
  "PASS beacon-lime-on" "PASS beacon-toggle-off" "plex_chrome_beacon_tb: PASS"
[[ "$RC_G" -eq 0 ]] || exit "$RC_G"
echo "test_plex_chrome_beacon_rtl_sim: PASS"
exit 0
