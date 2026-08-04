#!/usr/bin/env bash
# RED/GREEN twin: decode_stub must_be_absent (PRODUCT_NO_STUB post-fit teeth).
# Soft-skip is not a pass. EXECUTED must print.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$ROOT/scripts/check_quartus_fit_hierarchy.py"
CFG="$ROOT/tests/fixtures/critical_fit_hierarchy_product_no_stub.json"
WORKDIR="${ROOT}/Memory/lab/fitgate-hier-twin"
mkdir -p "$WORKDIR"

HDR='; Compilation Hierarchy Node ; ALMs needed [=A-B+C] ; [A] ALMs used in final placement ; [B] Estimate of ALMs recoverable by dense packing ; [C] Estimate of ALMs unavailable ; ALMs used for memory ; Combinational ALUTs ; Dedicated Logic Registers ; I/O Registers ; Block Memory Bits ; M10Ks ; DSP Blocks ; Pins ; Virtual Pins ; Full Hierarchy Name ; Entity Name ; Library Name ;'

# Rows meet min_* for product critical modules; no decode_stub hierarchy.
row() {
  # $1 node $2 aluts $3 regs $4 bits $5 m10k $6 full $7 entity
  printf ';          |%s| ; 100 ; 100 ; 0 ; 0 ; 0 ; %s ; %s ; 0 ; %s ; %s ; 0 ; 0 ; 0 ; %s ; %s ; work ;\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

{
  echo "$HDR"
  row 'ddr_frame_store:fstore' 4116 1828 159744 96 \
    '|sys_top|emu:emu|present_core:present|ddr_frame_store:fstore' 'ddr_frame_store'
  row 'present_core:present' 200 100 0 1 \
    '|sys_top|emu:emu|present_core:present' 'present_core'
  row 'stream_path:spath' 15589 7095 1000 4 \
    '|sys_top|emu:emu|stream_path:spath' 'stream_path'
  row 'ddr_bitstream_reader:ddr_stream' 200 150 0 1 \
    '|sys_top|emu:emu|stream_path:spath|ddr_bitstream_reader:ddr_stream' 'ddr_bitstream_reader'
  row 'plex_rbf_build_id:u_rbf_build_id' 12 32 0 0 \
    '|sys_top|emu:emu|plex_rbf_build_id:u_rbf_build_id' 'plex_rbf_build_id'
  row 'plex_delivery_path_stamp:u_delivery_path' 2 8 0 0 \
    '|sys_top|emu:emu|plex_delivery_path_stamp:u_delivery_path' 'plex_delivery_path_stamp'
} >"$WORKDIR/green_absent.fit.rpt"

{
  cat "$WORKDIR/green_absent.fit.rpt"
  row 'decode_stub:stub' 500 800 0 50 \
    '|sys_top|emu:emu|stream_path:spath|decode_stub:stub' 'decode_stub'
} >"$WORKDIR/red_stub_present.fit.rpt"

echo "=== GREEN: stub absent ==="
set +e
python3 "$CHK" --fit-rpt "$WORKDIR/green_absent.fit.rpt" --config "$CFG" \
  >"$WORKDIR/green.out" 2>"$WORKDIR/green.err"
g_rc=$?
set -e
echo "green true rc=$g_rc"
cat "$WORKDIR/green.out"
cat "$WORKDIR/green.err" || true

echo "=== RED: stub still fitted ==="
set +e
python3 "$CHK" --fit-rpt "$WORKDIR/red_stub_present.fit.rpt" --config "$CFG" \
  >"$WORKDIR/red.out" 2>"$WORKDIR/red.err"
r_rc=$?
set -e
echo "red true rc=$r_rc"
cat "$WORKDIR/red.err" || true

if [[ "$g_rc" -ne 0 ]]; then
  echo "FAIL expected green absent rc=0 got $g_rc" >&2
  exit 1
fi
if ! grep -q 'FIT_HIERARCHY_ABSENT_OK decode_stub' "$WORKDIR/green.out"; then
  echo "FAIL green must print FIT_HIERARCHY_ABSENT_OK decode_stub" >&2
  exit 1
fi
if [[ "$r_rc" -eq 0 ]]; then
  echo "FAIL expected red stub-present rc!=0 got 0" >&2
  exit 1
fi
if ! grep -q 'must_be_absent' "$WORKDIR/red.err"; then
  echo "FAIL red error must name must_be_absent" >&2
  exit 1
fi
echo "EXECUTED fit_hierarchy_must_be_absent GREEN_rc=0 RED_rc=$r_rc"
exit 0
