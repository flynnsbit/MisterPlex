#!/usr/bin/env bash
# present_scale_4_3_2ppc — Y-plane 2-PPC through RAM_LAT=1 tap pipeline.
# Green: const + H/V ramp + comb req + HV. RED: FAULT_PHASE_DST / INVERT.
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
BUILD="$ROOT/build/verilator/present_scale_4_3_2ppc"
mkdir -p "$BUILD"
sv=(
  "$ROOT/tests/rtl/present_scale_4_3_2ppc_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_scale_4_3_2ppc.sv"
  "$ROOT/tests/rtl/present_scale_4_3_2ppc_tb.cpp"
)
vf=(--cc --exe --build --top-module present_scale_4_3_2ppc_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
  -CFLAGS "-std=c++17 -O2")

echo "=== BUILD scale_4_3_2ppc product ===" >&2
"$RUN" "${vf[@]}" --Mdir "$BUILD" "${sv[@]}"

set +e
OUT="$("$BUILD/Vpresent_scale_4_3_2ppc_tb" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "product true rc=$RC"
assert_exec product "$OUT" \
  "CASE scale43_2ppc_const EXECUTED" \
  "CASE scale43_2ppc_ramp EXECUTED" \
  "CASE scale43_2ppc_vramp EXECUTED" \
  "CASE scale43_2ppc_hv EXECUTED" \
  "CASE scale43_2ppc_req EXECUTED" \
  "CASE scale43_2ppc_fault EXECUTED" \
  "PASS scale43_2ppc constant-color" \
  "PASS scale43_2ppc H-ramp oracle" \
  "PASS scale43_2ppc V-ramp+edge" \
  "PASS scale43_2ppc comb req" \
  "PASS scale43_2ppc discriminant"
[[ "$RC" -eq 0 ]] || exit 1

run_fault() {
  local def="$1" lab="$2"
  local bd="$ROOT/build/verilator/present_scale_4_3_2ppc_$lab"
  echo "=== RED $def ===" >&2
  mkdir -p "$bd"
  "$RUN" "${vf[@]}" --Mdir "$bd" +define+"$def" "${sv[@]}"
  set +e
  local o r
  o="$("$bd/Vpresent_scale_4_3_2ppc_tb" 2>&1)"; r=$?
  set -e
  printf '%s\n' "$o"
  echo "${lab} true rc=$r"
  assert_exec "$lab" "$o" "CASE scale43_2ppc_fault EXECUTED"
  if [[ "$r" -eq 0 ]]; then
    echo "FAIL: $def must fail product pixel oracle (red twin dead)" >&2
    exit 1
  fi
  echo "PASS red-check $def true_rc=$r"
}

run_fault PRESENT_SCALE_4_3_FAULT_PHASE_DST fault_phase_dst
run_fault PRESENT_SCALE_4_3_FAULT_INVERT fault_invert

echo "OK present_scale_4_3_2ppc_rtl_sim: Y RAM_LAT=1 pixels + V-ramp + RED"
exit 0
