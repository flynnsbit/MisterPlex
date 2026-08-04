#!/usr/bin/env bash
# Verilator sim for plex_rbf_build_id — GREEN healthy + RED fault twin.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MDIR="$ROOT/build/verilator/plex_rbf_build_id"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/plex_rbf_build_id.sv"
TOP="$ROOT/tests/rtl/plex_rbf_build_id_tb_top.sv"
TB="$ROOT/tests/rtl/plex_rbf_build_id_tb.cpp"
mkdir -p "$MDIR"

echo "=== test_plex_rbf_build_id_rtl_sim EXECUTED ==="
test -f "$RTL" || { echo "FAIL missing $RTL" >&2; echo "true rc=2"; exit 2; }

set +e
"$ROOT/scripts/run_verilator.sh" --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module plex_rbf_build_id_tb_top \
  -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
v_rc=$?
set -e
echo "verilator_build true rc=$v_rc"
if [[ "$v_rc" -ne 0 ]]; then
  echo "FAIL verilator build" >&2
  echo "true rc=$v_rc"
  exit "$v_rc"
fi

BIN="$MDIR/Vplex_rbf_build_id_tb_top"
test -x "$BIN" || BIN="$MDIR/Vplex_rbf_build_id_tb_top.exe"
set +e
out=$("$BIN" 2>&1)
rc=$?
set -e
printf '%s\n' "$out"
echo "sim true rc=$rc"
echo "SIM_ARTIFACT=$BIN"

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL plex_rbf_build_id sim" >&2
  echo "true rc=$rc"
  exit "$rc"
fi
echo "$out" | grep -q 'CASE EXECUTED' || { echo "FAIL no CASE EXECUTED" >&2; exit 1; }
echo "$out" | grep -q 'measured_id_valid_good=1' || { echo "FAIL good valid" >&2; exit 1; }
echo "$out" | grep -q 'measured_id_valid_fault=0' || { echo "FAIL fault not red" >&2; exit 1; }
echo "PASS test_plex_rbf_build_id_rtl_sim"
echo "true rc=0"
exit 0
