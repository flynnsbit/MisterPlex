#!/usr/bin/env bash
# Present vs publish contention on arbiter3 + publish_path (w-mem).
# Product quantum path must PASS; FAULT sticky twin must REPRO_OK.
# true rc captured directly (never through a pipe alone).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"

RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl/ddr_publish_contended_tb.sv"
GOOD_MDIR="$ROOT/build/verilator/ddr_publish_contended_good"
FAULT_MDIR="$ROOT/build/verilator/ddr_publish_contended_fault"

echo "=== test_ddr_publish_contended_rtl_sim EXECUTED ==="
test -f "$TB"
test -f "$RTL_DIR/ddr_publish_path.sv"
test -f "$RTL_DIR/ddr_publish_engine.sv"
test -f "$RTL_DIR/ddr_publish_job.sv"
test -f "$RTL_DIR/ddr_i420_bank_geom.sv"
test -f "$RTL_DIR/ddr_bus_arbiter3.sv"
test -f "$RTL_DIR/async_fifo.sv"
command -v verilator >/dev/null || { echo "FAIL verilator missing"; exit 1; }

COMMON=(
  "$RTL_DIR/async_fifo.sv"
  "$RTL_DIR/ddr_bus_arbiter3.sv"
  "$RTL_DIR/ddr_i420_bank_geom.sv"
  "$RTL_DIR/ddr_publish_job.sv"
  "$RTL_DIR/ddr_publish_engine.sv"
  "$RTL_DIR/ddr_publish_path.sv"
  "$TB"
)
VFLAGS=(--binary -j 0 -Wno-fatal --top-module ddr_publish_contended_tb)

echo "=== A) FAULT sticky-no-quantum (expect REPRO_OK) ==="
rm -rf "$FAULT_MDIR"
verilator "${VFLAGS[@]}" --Mdir "$FAULT_MDIR" \
  -DDDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM \
  "${COMMON[@]}"
set +e
FAULT_OUT="$("$FAULT_MDIR/Vddr_publish_contended_tb" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT" | tail -30
echo "fault true rc=$FAULT_RC"
echo "$FAULT_OUT" | grep -q 'REPRO_OK' || { echo "FAIL FAULT missing REPRO_OK"; exit 2; }
[[ "$FAULT_RC" -eq 0 ]] || { echo "FAIL FAULT rc=$FAULT_RC"; exit 2; }

echo "=== B) PRODUCT quantum + present fence (expect PASS all) ==="
rm -rf "$GOOD_MDIR"
verilator "${VFLAGS[@]}" --Mdir "$GOOD_MDIR" "${COMMON[@]}"
set +e
GOOD_OUT="$("$GOOD_MDIR/Vddr_publish_contended_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT" | tail -40
echo "product true rc=$GOOD_RC"
echo "$GOOD_OUT" | grep -q 'PASS ddr_publish_contended_tb all' || {
  echo "FAIL product missing PASS line"; exit 2;
}
echo "$GOOD_OUT" | grep -q 'PASS G0' || { echo "FAIL missing G0"; exit 2; }
echo "$GOOD_OUT" | grep -q 'PASS G1' || { echo "FAIL missing G1"; exit 2; }
echo "$GOOD_OUT" | grep -q 'PASS G2' || { echo "FAIL missing G2"; exit 2; }
[[ "$GOOD_RC" -eq 0 ]] || { echo "FAIL product rc=$GOOD_RC"; exit 2; }

echo "PASS test_ddr_publish_contended_rtl_sim"
echo "true rc=0"
exit 0
