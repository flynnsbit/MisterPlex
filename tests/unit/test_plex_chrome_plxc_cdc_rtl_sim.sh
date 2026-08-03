#!/usr/bin/env bash
# Hierarchy PLXC CDC: consecutive loader host_we bursts across 20→74.25 MHz.
# Product async FIFO delivers all beats; edge-detect twin collapses (red).
# true rc direct. Soft-skip never for logic failures.
set -euo pipefail

assert_exec() {
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
  "$ROOT/tests/rtl/plex_chrome_plxc_cdc_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_plxc_cdc.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv"
  "$ROOT/tests/rtl/plex_chrome_plxc_cdc_tb.cpp"
)
VFLAGS=(--cc --exe --build --top-module plex_chrome_plxc_cdc_tb
  -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
  -CFLAGS "-std=c++17 -O2")

BDIR="$ROOT/build/verilator/plex_chrome_plxc_cdc"
mkdir -p "$BDIR"

echo "=== BUILD plex_chrome_plxc_cdc TB ===" >&2
"$RUN" "${VFLAGS[@]}" --Mdir "$BDIR" --prefix Vplex_chrome_plxc_cdc_tb "${SV[@]}"
echo "build true rc=$?"

echo "=== RUN ===" >&2
set +e
OUT="$("$BDIR/Vplex_chrome_plxc_cdc_tb" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "plex_chrome_plxc_cdc_tb true rc=$RC"

assert_exec "plxc-cdc" "$OUT" \
  "EXECUTED product_burst" \
  "PASS product_burst" \
  "EXECUTED edge_fault_burst" \
  "PASS edge_fault_collapse" \
  "EXECUTED single_beat" \
  "PASS single_beat" \
  "plex_chrome_plxc_cdc_tb: PASS"

# Static product path: no rising-edge PLXC we in sys_top
if grep -n 'plxc_ext_we_d2 & ~plxc_ext_we_d3' "$ROOT/fpga/Plex_MiSTer/sys/sys_top.v"; then
  echo "FAIL sys_top still has edge-detect PLXC CDC" >&2
  exit 1
fi
if ! grep -q 'plex_chrome_plxc_cdc' "$ROOT/fpga/Plex_MiSTer/sys/sys_top.v"; then
  echo "FAIL sys_top missing plex_chrome_plxc_cdc instance" >&2
  exit 1
fi
if ! grep -q 'plex_chrome_plxc_cdc' "$ROOT/fpga/Plex_MiSTer/files.qip"; then
  echo "FAIL files.qip missing plex_chrome_plxc_cdc.sv" >&2
  exit 1
fi
echo "OK sys_top uses async FIFO CDC (no d2&~d3)"

if [[ "$RC" -ne 0 ]]; then
  echo "test_plex_chrome_plxc_cdc_rtl_sim: FAIL rc=$RC" >&2
  exit "$RC"
fi
echo "test_plex_chrome_plxc_cdc_rtl_sim: PASS"
exit 0
