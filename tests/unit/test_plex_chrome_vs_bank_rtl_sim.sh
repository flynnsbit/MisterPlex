#!/usr/bin/env bash
# plex_chrome bank map: live-hold oracle + VS coincidence + invert red twin.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || { echo "FAIL $label compile-only/empty" >&2; exit 2; }
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
  "$ROOT/tests/rtl/plex_chrome_vs_bank_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv"
  "$ROOT/tests/rtl/plex_chrome_vs_bank_tb.cpp"
)

run_one() {
  local name="$1" define="$2" expect_rc="$3"; shift 3
  local bdir="$ROOT/build/verilator/plex_chrome_vs_bank_${name}"
  mkdir -p "$bdir"
  local vf=(--cc --exe --build --top-module plex_chrome_vs_bank_tb
    -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SELRANGE
    -CFLAGS "-std=c++17 -O2")
  if [[ -n "$define" ]]; then
    vf+=(+define+"$define")
  fi
  echo "=== BUILD vs_bank $name define=$define ===" >&2
  "$RUN" "${vf[@]}" --Mdir "$bdir" "${SV[@]}"
  echo "=== RUN vs_bank $name ===" >&2
  set +e
  local out rc
  out="$(VS_BANK_CASE="$name" "$bdir/Vplex_chrome_vs_bank_tb" 2>&1)"
  rc=$?
  set -e
  printf "%s\n" "$out"
  echo "vs_bank_${name} true rc=$rc"
  assert_sim_executed "vs_bank-$name" "$out" "$@"
  if [[ "$rc" -ne "$expect_rc" ]]; then
    echo "FAIL vs_bank_$name want rc=$expect_rc got $rc" >&2
    exit 1
  fi
}

run_one product "" 0 \
  "EXECUTED live_hold" "PASS live_hold" \
  "EXECUTED vs_bank_product" "PASS vs_bank_product" \
  "plex_chrome_vs_bank_tb: PASS"

run_one fault "PLEX_CHROME_FAULT_VS_BANK" 0 \
  "EXECUTED vs_bank_fault" "PASS vs_bank_fault" \
  "plex_chrome_vs_bank_tb: PASS"

run_one invert "PLEX_CHROME_FAULT_INVERT_STAGING" 0 \
  "EXECUTED live_hold" "PASS live_hold_invert" \
  "plex_chrome_vs_bank_tb: PASS"

echo "test_plex_chrome_vs_bank_rtl_sim: PASS"
exit 0
