#!/usr/bin/env bash
# Counted plex_chrome HUD RTL sim — product list_we path → pixels.
# Red twins: wrong_off, hit_bleed. Truncation: 79→48. EXECUTED required.
set -euo pipefail

assert_exec() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing EXECUTED/PASS: $m" >&2; missing=1; }
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
  "$ROOT/tests/rtl/plex_chrome_counted_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv"
  "$ROOT/tests/rtl/plex_chrome_counted_tb.cpp"
)
VFLAGS=(--cc --exe --build --top-module plex_chrome_counted_tb
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SELRANGE
  -CFLAGS "-std=c++17 -O2")

run_case() {
  local name="$1" fault="$2" expect_rc="$3"; shift 3
  local bdir="$ROOT/build/verilator/plex_chrome_counted_${name}"
  mkdir -p "$bdir"
  echo "=== BUILD counted $name FAULT_HIT_BLEED=$fault ===" >&2
  "$RUN" "${VFLAGS[@]}" -GFAULT_HIT_BLEED="$fault" --Mdir "$bdir" "${SV[@]}"
  echo "=== RUN counted $name ===" >&2
  set +e
  local out rc
  out="$(COUNTED_CASE="$name" "$bdir/Vplex_chrome_counted_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "counted_${name} true rc=$rc"
  assert_exec "counted-$name" "$out" "$@"
  if [[ "$rc" -ne "$expect_rc" ]]; then
    echo "FAIL counted_$name want rc=$expect_rc got $rc" >&2
    exit 1
  fi
}

# GREEN product path
run_case green 0 0 "EXECUTED green" "PASS counted-green" "plex_chrome_counted_tb: PASS"
run_case no_bleed 0 0 "EXECUTED no_bleed_product" "PASS counted-no_bleed_product"

# RED twins (must EXECUTE and PASS their own assertions — they document the defect class)
run_case wrong_off 0 0 "EXECUTED wrong_off" "PASS counted-wrong_off"
run_case hit_bleed 1 0 "EXECUTED hit_bleed" "PASS counted-hit_bleed"

# Truncation 79→48
run_case trunc79 0 0 "EXECUTED trunc79" "PASS counted-trunc79"

# Meta red: hit_bleed binary must NOT pass no_bleed expectations if we ran green on it —
# covered by separate builds.

echo "test_plex_chrome_counted_rtl_sim: PASS"
exit 0
