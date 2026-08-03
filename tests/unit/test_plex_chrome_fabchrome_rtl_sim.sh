#!/usr/bin/env bash
# Red-before-green: fabric playback chrome demo + magenta signature.
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

BUILD_R="$ROOT/build/verilator/plex_chrome_fabchrome_red"
BUILD_G="$ROOT/build/verilator/plex_chrome_fabchrome"
mkdir -p "$BUILD_R" "$BUILD_G"

sv=(
  "$ROOT/tests/rtl/plex_chrome_fabchrome_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv"
  "$ROOT/tests/rtl/plex_chrome_fabchrome_tb.cpp"
)
vflags=(--cc --exe --build --top-module plex_chrome_fabchrome_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD fabchrome RED ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD_R" "${sv[@]}"
echo "=== RUN fabchrome RED ===" >&2
set +e
OUT_R="$(FAULT_NO_FAB_CHROME=1 "$BUILD_R/Vplex_chrome_fabchrome_tb" 2>&1)"
RC_R=$?
set -e
printf '%s\n' "$OUT_R"
echo "fabchrome_red true rc=$RC_R"
assert_sim_executed "fabchrome_red" "$OUT_R" "PASS fabchrome-red-no-paint" "plex_chrome_fabchrome_tb: PASS"
[[ "$RC_R" -eq 0 ]] || exit "$RC_R"

echo "=== BUILD fabchrome GREEN ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BUILD_G" "${sv[@]}"
echo "=== RUN fabchrome GREEN ===" >&2
set +e
OUT_G="$("$BUILD_G/Vplex_chrome_fabchrome_tb" 2>&1)"
RC_G=$?
set -e
printf '%s\n' "$OUT_G"
echo "fabchrome_green true rc=$RC_G"
assert_sim_executed "fabchrome_green" "$OUT_G" \
  "PASS fabchrome-magenta" "PASS fabchrome-stopped-glyphs" "PASS fabchrome-amber-bar" \
  "PASS fabchrome-panel" "PASS fabchrome-video-underlay" "plex_chrome_fabchrome_tb: PASS"
[[ "$RC_G" -eq 0 ]] || exit "$RC_G"

echo "test_plex_chrome_fabchrome_rtl_sim: PASS"
exit 0
