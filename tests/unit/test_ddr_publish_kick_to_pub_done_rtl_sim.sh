#!/usr/bin/env bash
# Offline Verilator compose TB: kick_mbox → path/eng → PLXH done (or named STOP).
# PRODUCT_WIRE m2 mux + arb3 + f2sdram model. NO device / NO Quartus / FIT_GO=NO.
# true rc=0 only if C0 + C4 + C3_fault PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"

RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
# Prefer local integ RTL; allow fleet-test TB copy if present elsewhere
TB="$ROOT/tests/rtl/ddr_publish_kick_to_pub_done_tb.sv"
MDIR="$ROOT/build/verilator/ddr_publish_kick_to_pub_done_tb"

echo "=== test_ddr_publish_kick_to_pub_done_rtl_sim EXECUTED ==="
echo "ROOT=$ROOT"
echo "TB=$TB"
echo "RTL_DIR=$RTL_DIR"

test -f "$TB" || { echo "FAIL missing TB"; exit 1; }
test -f "$RTL_DIR/ddr_publish_kick_mbox.sv" || { echo "FAIL missing kick_mbox"; exit 1; }
test -f "$RTL_DIR/ddr_publish_path.sv" || { echo "FAIL missing path"; exit 1; }
test -f "$RTL_DIR/ddr_publish_engine.sv" || { echo "FAIL missing engine"; exit 1; }
test -f "$RTL_DIR/ddr_publish_job.sv" || { echo "FAIL missing job"; exit 1; }
test -f "$RTL_DIR/ddr_i420_bank_geom.sv" || { echo "FAIL missing geom"; exit 1; }
test -f "$RTL_DIR/ddr_bus_arbiter3.sv" || { echo "FAIL missing arb3"; exit 1; }
test -f "$RTL_DIR/async_fifo.sv" || { echo "FAIL missing async_fifo"; exit 1; }
test -f "$ROOT/tests/rtl/mplex_hold_lcell_sim.sv" || { echo "FAIL missing mplex_hold stub"; exit 1; }
command -v verilator >/dev/null || { echo "FAIL verilator missing"; exit 1; }

COMMON=(
  "$ROOT/tests/rtl/mplex_hold_lcell_sim.sv"
  "$RTL_DIR/async_fifo.sv"
  "$RTL_DIR/ddr_bus_arbiter3.sv"
  "$RTL_DIR/ddr_i420_bank_geom.sv"
  "$RTL_DIR/ddr_publish_job.sv"
  "$RTL_DIR/ddr_publish_engine.sv"
  "$RTL_DIR/ddr_publish_path.sv"
  "$RTL_DIR/ddr_publish_kick_mbox.sv"
  "$TB"
)
VFLAGS=(--binary -j 0 -Wno-fatal --top-module ddr_publish_kick_to_pub_done_tb)

rm -rf "$MDIR"
echo "=== verilator build ==="
verilator "${VFLAGS[@]}" --Mdir "$MDIR" "${COMMON[@]}"

echo "=== sim ==="
set +e
OUT="$("$MDIR/Vddr_publish_kick_to_pub_done_tb" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT" | tail -100
echo "sim true rc=$RC"

# Always surface named stop / sole pin for status harvest (even on FAIL)
echo "$OUT" | grep -E 'FAIL_BUSYSTUCK_0x21|FAIL_FALSE_DONE|FAIL_WRONG_BANK|STOP_S|R9_SOLE=|R8_SOLE=|R6_SOLE=|C0_RANK|C0_EVIDENCE|G_CONTENT|G_BANK0_LAND|PASS C0|PASS C4|PASS C3' || true

if echo "$OUT" | grep -q 'PASS ddr_publish_kick_to_pub_done_tb all' \
  && echo "$OUT" | grep -q 'PASS C0' \
  && echo "$OUT" | grep -q 'PASS C4' \
  && echo "$OUT" | grep -q 'PASS C3' \
  && [[ "$RC" -eq 0 ]]; then
  echo "PASS test_ddr_publish_kick_to_pub_done_rtl_sim"
  echo "true rc=0"
  exit 0
fi

echo "FAIL test_ddr_publish_kick_to_pub_done_rtl_sim (compose residual — see STOP_*)"
echo "true rc=1"
exit 1
