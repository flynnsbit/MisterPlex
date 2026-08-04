#!/usr/bin/env bash
# Verilator sim for plex_rbf_build_id — GREEN healthy + RED fault twin.
# Soft-skip≠PASS. true rc captured directly (never through a pipe).
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
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
MDIR="$ROOT/build/verilator/plex_rbf_build_id"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/plex_rbf_build_id.sv"
TOP="$ROOT/tests/rtl/plex_rbf_build_id_tb_top.sv"
TB="$ROOT/tests/rtl/plex_rbf_build_id_tb.cpp"
mkdir -p "$MDIR"

echo "=== test_plex_rbf_build_id_rtl_sim EXECUTED ==="

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

test -f "$RTL" || { echo "FAIL missing $RTL" >&2; echo "true rc=2"; exit 2; }

set +e
"$RUN_VERILATOR" --cc --exe --build \
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

# GREEN path must execute and PASS; FAULT twin is in-binary (id_valid_fault=0).
assert_sim_executed "plex_rbf_build_id" "$out" \
  "CASE EXECUTED" \
  "measured_id_valid_good=1" \
  "measured_id_valid_fault=0" \
  "PASS plex_rbf_build_id_tb"

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL plex_rbf_build_id sim true rc=$rc" >&2
  echo "true rc=$rc"
  exit "$rc"
fi

# Explicit red-check wording for gate_false_green_guard corpus.
if ! grep -q 'measured_id_valid_fault=0' <<<"$out"; then
  echo "FAIL plex_rbf_build_id red-check: FAULT_ZERO_STAMP twin did not clear id_valid" >&2
  exit 1
fi
echo "OK plex_rbf_build_id red-check: FAULT_ZERO_STAMP cleared id_valid (true rc twin path)"
echo "PASS test_plex_rbf_build_id_rtl_sim"
echo "true rc=0"
exit 0
