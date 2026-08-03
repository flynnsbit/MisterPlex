#!/usr/bin/env bash
# present_scale_4_3 product 4/3 path — green product + RED invert/phase_obo.
set -euo pipefail

assert_exec() {
  local label="$1" log="$2"; shift 2
  local m missing=0
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e
VER="$($RUN --version 2>&1)"; VRC=$?
set -e
if [[ "$VRC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  exit 3
fi
[[ "$VRC" -eq 0 ]] || exit "$VRC"

echo "RTL SIM: $VER" >&2
BUILD="$ROOT/build/verilator/present_scale_4_3"
mkdir -p "$BUILD"
sv=(
  "$ROOT/tests/rtl/present_scale_4_3_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_scale_4_3.sv"
  "$ROOT/tests/rtl/present_scale_4_3_tb.cpp"
)
vf=(--cc --exe --build --top-module present_scale_4_3_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD scale_4_3 product ===" >&2
"$RUN" "${vf[@]}" --Mdir "$BUILD" "${sv[@]}"

set +e
OUT="$("$BUILD/Vpresent_scale_4_3_tb" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "product true rc=$RC"
assert_exec product "$OUT" "CASE scale43_product EXECUTED" "PASS present_scale_4_3 product" \
  "PASS scale43 neg"
[[ "$RC" -eq 0 ]] || exit 1

run_fault() {
  local def="$1" lab="$2"
  local bd="$ROOT/build/verilator/present_scale_4_3_$lab"
  echo "=== RED $def ===" >&2
  mkdir -p "$bd"
  "$RUN" "${vf[@]}" --Mdir "$bd" +define+"$def" "${sv[@]}"
  set +e
  local o r
  o="$("$bd/Vpresent_scale_4_3_tb" 2>&1)"; r=$?
  set -e
  printf '%s\n' "$o"
  echo "${lab} true rc=$r"
  assert_exec "$lab" "$o" "CASE scale43_product EXECUTED"
  if [[ "$r" -eq 0 ]]; then
    echo "FAIL: $def must fail product (red twin dead)" >&2
    exit 1
  fi
  echo "PASS red-check $def true_rc=$r"
}

run_fault PRESENT_SCALE_4_3_FAULT_INVERT fault_invert
run_fault PRESENT_SCALE_4_3_FAULT_PHASE_OBO fault_phase

echo "OK present_scale_4_3_rtl_sim: product + RED invert/phase_obo"
exit 0
