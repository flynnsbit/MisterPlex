#!/usr/bin/env bash
# Fabric publish engine RTL sim (w-mem). true rc direct; soft-skip ≠ pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"
MDIR="$ROOT/build/verilator/ddr_publish_engine_tb"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/ddr_publish_engine.sv"
TB="$ROOT/tests/rtl/ddr_publish_engine_tb.sv"
echo "=== test_ddr_publish_engine_rtl_sim EXECUTED ==="
test -f "$RTL" && test -f "$TB"
command -v verilator >/dev/null || { echo "FAIL verilator missing"; exit 1; }
rm -rf "$MDIR"
verilator --binary -j 0 -Wno-fatal --top-module ddr_publish_engine_tb \
  --Mdir "$MDIR" "$RTL" "$TB"
set +e
out=$("$MDIR/Vddr_publish_engine_tb" 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | tail -20
echo "sim true rc=$rc"
echo "$out" | grep -q 'PASS ddr_publish_engine_tb all' || { echo "FAIL missing PASS line"; exit 1; }
echo "$out" | grep -q 'PASS G1' || { echo "FAIL missing G1"; exit 1; }
echo "$out" | grep -q 'PASS G_NEG' || { echo "FAIL missing G_NEG"; exit 1; }
[[ "$rc" -eq 0 ]] || { echo "FAIL sim rc"; exit 1; }
echo "PASS test_ddr_publish_engine_rtl_sim"
echo "true rc=0"
exit 0
