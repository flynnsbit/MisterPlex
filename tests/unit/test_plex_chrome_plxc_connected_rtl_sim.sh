#!/usr/bin/env bash
# Connected loader → CDC FIFO → host_if. Near-full freeze must conserve every beat.
# Catches registered-valid one-slot drop (rd-duck on 96e4a50d).
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
  "$ROOT/tests/rtl/plex_chrome_plxc_connected_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_plxc_cdc.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv"
  "$ROOT/tests/rtl/plex_chrome_plxc_connected_tb.cpp"
)
VFLAGS=(--cc --exe --build --top-module plex_chrome_plxc_connected_tb
  -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT
  -CFLAGS "-std=c++17 -O2")

BDIR="$ROOT/build/verilator/plex_chrome_plxc_connected"
mkdir -p "$BDIR"

echo "=== BUILD plex_chrome_plxc_connected TB ===" >&2
"$RUN" "${VFLAGS[@]}" --Mdir "$BDIR" --prefix Vplex_chrome_plxc_connected_tb "${SV[@]}"
echo "build true rc=$?"

echo "=== RUN ===" >&2
set +e
OUT="$("$BDIR/Vplex_chrome_plxc_connected_tb" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "plex_chrome_plxc_connected_tb true rc=$RC"

assert_exec "plxc-connected" "$OUT" \
  "EXECUTED connected_near_full" \
  "PASS connected_near_full" \
  "EXECUTED connected_second_xact" \
  "PASS connected_second_xact" \
  "EXECUTED connected_reset_while_rd_frozen" \
  "PASS connected_reset_while_rd_frozen" \
  "plex_chrome_plxc_connected_tb: PASS"

# Async assert required so freeze+RESET clears rd domain (rd-duck)
if ! grep -q 'posedge wr_clk or posedge wr_rst' \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_plxc_cdc.sv"; then
  echo "FAIL plxc_cdc missing async wr domain reset" >&2
  exit 1
fi
if ! grep -q 'posedge rd_clk or posedge rd_rst' \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_plxc_cdc.sv"; then
  echo "FAIL plxc_cdc missing async rd domain reset" >&2
  exit 1
fi

# Product loader must use comb host_we (not reg advance-before-accept)
if grep -nE 'output\s+reg\s+.*host_we' "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv"; then
  echo "FAIL loader host_we is reg again (registered-valid hole)" >&2
  exit 1
fi
if ! grep -q 'assign host_we = push_list || push_ctrl' \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_ddr_loader.sv"; then
  echo "FAIL loader missing comb host_we assign" >&2
  exit 1
fi
if ! grep -q 'PLXC_EXT_READY' "$ROOT/fpga/Plex_MiSTer/sys/sys_top.v"; then
  echo "FAIL sys_top missing PLXC_EXT_READY backpressure" >&2
  exit 1
fi

if [[ "$RC" -ne 0 ]]; then
  echo "test_plex_chrome_plxc_connected_rtl_sim: FAIL" >&2
  exit "$RC"
fi
echo "test_plex_chrome_plxc_connected_rtl_sim: PASS"
exit 0
