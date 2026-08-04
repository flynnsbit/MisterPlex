#!/usr/bin/env bash
# Verilator: ddr_contention_status observed counters (w-plxd).
# POS contended m0+m2; NEG idle stalls=0; NEG solo free-bus no false stall.
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
MDIR="$ROOT/build/verilator/ddr_contention_status"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/ddr_contention_status.sv"
TOP="$ROOT/tests/rtl/ddr_contention_status_tb_top.sv"
TB="$ROOT/tests/rtl/ddr_contention_status_tb.cpp"
mkdir -p "$MDIR"

echo "=== test_ddr_contention_status_rtl_sim EXECUTED ==="

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP-NOT-PASS RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

test -f "$RTL" || { echo "FAIL missing $RTL" >&2; exit 2; }

set +e
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module ddr_contention_status_tb_top \
  -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"
v_rc=$?
set -e
echo "verilator_build true rc=$v_rc"
if [[ "$v_rc" -ne 0 ]]; then
  echo "FAIL verilator build" >&2
  exit "$v_rc"
fi

BIN="$MDIR/Vddr_contention_status_tb_top"
test -x "$BIN" || BIN="$MDIR/Vddr_contention_status_tb_top.exe"
set +e
out=$("$BIN" 2>&1)
rc=$?
set -e
printf '%s\n' "$out"
echo "sim true rc=$rc"

assert_sim_executed "ddr_contention_status" "$out" \
  "CASE EXECUTED ddr_contention_status_tb" \
  "PASS NEG_idle" \
  "PASS NEG_solo_m0_free" \
  "PASS POS_contended_m0_m2" \
  "PASS POS_ddr_busy_attr" \
  "PASS ddr_contention_status_tb"

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL ddr_contention_status sim true rc=$rc" >&2
  exit "$rc"
fi

echo "PASS test_ddr_contention_status_rtl_sim"
echo "true rc=0"
exit 0
