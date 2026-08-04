#!/usr/bin/env bash
# Verilator: ddr_frame_abi_select 480p stay + 1280x720→720p ABI.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0 m
  if [[ -z "${log//[$' \t\r\n']/}" ]]; then
    echo "FAIL $label: empty sim log — compile-only is not a pass" >&2
    exit 2
  fi
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
echo "=== test_ddr_frame_abi_select_rtl_sim EXECUTED ==="
OUT="$ROOT/build/verilator/ddr_frame_abi_select"
mkdir -p "$OUT"
"$RUN_VERILATOR" --cc --exe --build --Mdir "$OUT" \
  --top-module ddr_frame_abi_select_tb_top \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  +incdir+"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb_top.sv" \
  "$ROOT/tests/rtl/ddr_frame_abi_select_tb.cpp"
echo "verilator_build true rc=$?"
set +e
SIM_OUT="$("$OUT/Vddr_frame_abi_select_tb_top" 2>&1)"
SIM_RC=$?
set -e
printf '%s\n' "$SIM_OUT"
echo "sim true rc=$SIM_RC"
[[ "$SIM_RC" -eq 0 ]]
assert_sim_executed "ddr_frame_abi_select" "$SIM_OUT" \
  "ddr_frame_abi_select: OK" "1280x720"
echo "PASS test_ddr_frame_abi_select_rtl_sim"
