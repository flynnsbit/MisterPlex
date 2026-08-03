#!/usr/bin/env bash
# Fabric content window — red-before-green + 720p-ready Verilator gate.
# A) legacy fixed FRAME map → REPRO quarter-size class
# B) win_enable 320x240 on 529x480 → PASS full stretch
# C) legacy 480p identity → PASS
# D) win_enable 1280x720 on 529x480 DE → PASS reaches 1279/719 (11b path)
# E) win_enable 1280x720 on 1280x720 DE → PASS identity
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

run_mode() {
  local mode="$1"
  set +e
  local out rc
  out="$(WINDOW_MODE="$mode" "$BUILD/Vpresent_content_window_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "${mode} true rc=$rc"
  eval "${mode}_OUT=$(printf '%q' "$out")"
  eval "${mode}_RC=$rc"
}

echo "=== A) LEGACY fixed map ===" >&2
set +e
LEGACY_OUT="$(WINDOW_MODE=legacy "$BUILD/Vpresent_content_window_tb" 2>&1)"
LEGACY_RC=$?
set -e
printf '%s\n' "$LEGACY_OUT"
echo "legacy true rc=$LEGACY_RC"

echo "=== B) WINDOW 320x240 ===" >&2
set +e
WINDOW_OUT="$(WINDOW_MODE=window "$BUILD/Vpresent_content_window_tb" 2>&1)"
WINDOW_RC=$?
set -e
printf '%s\n' "$WINDOW_OUT"
echo "window true rc=$WINDOW_RC"

echo "=== C) LEGACY 480p identity ===" >&2
set +e
L480_OUT="$(WINDOW_MODE=legacy480 "$BUILD/Vpresent_content_window_tb" 2>&1)"
L480_RC=$?
set -e
printf '%s\n' "$L480_OUT"
echo "legacy480 true rc=$L480_RC"

echo "=== D) WINDOW 1280x720 on 529x480 DE ===" >&2
set +e
W720_OUT="$(WINDOW_MODE=720de480 "$BUILD/Vpresent_content_window_tb" 2>&1)"
W720_RC=$?
set -e
printf '%s\n' "$W720_OUT"
echo "720de480 true rc=$W720_RC"

echo "=== E) WINDOW 1280x720 identity DE ===" >&2
set +e
W720ID_OUT="$(WINDOW_MODE=720id "$BUILD/Vpresent_content_window_tb" 2>&1)"
W720ID_RC=$?
set -e
printf '%s\n' "$W720ID_OUT"
echo "720id true rc=$W720ID_RC"

assert_sim_executed "legacy" "$LEGACY_OUT" \
  "REPRO_OK legacy_fixed_map" "quarter_class=1" "PASS race model legacy"
assert_sim_executed "window" "$WINDOW_OUT" \
  "PASS present_content_window_320" "PASS race model window"
assert_sim_executed "legacy480" "$L480_OUT" \
  "PASS legacy_480p_identity"
assert_sim_executed "720de480" "$W720_OUT" \
  "PASS present_content_window_720_on_480de"
assert_sim_executed "720id" "$W720ID_OUT" \
  "PASS present_content_window_720_identity"

if [[ "$LEGACY_RC" -ne 0 || "$WINDOW_RC" -ne 0 || "$L480_RC" -ne 0 || "$W720_RC" -ne 0 || "$W720ID_RC" -ne 0 ]]; then
  echo "FAIL: one or more WINDOW_MODE cases returned non-zero" >&2
  exit 1
fi
if grep -q 'quarter_class=1' <<<"$WINDOW_OUT"; then
  echo "FAIL: window mode must not be quarter-class" >&2
  exit 1
fi

echo "OK present_content_window_rtl_sim: REPRO legacy + PASS 320 + PASS 480id + PASS 720on480 + PASS 720id"
exit 0
