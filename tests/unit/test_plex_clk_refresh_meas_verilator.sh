#!/usr/bin/env bash
# Verilator: refresh measure PASS@24.242 FAIL@16.16 EXACT24_not_product.
# Soft-skip≠PASS. true rc captured directly (never through a pipe).
# gate_false_green_guard: assert_sim_executed + red-check required.
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
MDIR="$ROOT/build/verilator/plex_clk_refresh_meas"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/plex_clk_status.sv"
TOP="$ROOT/tests/rtl/plex_clk_refresh_meas_tb_top.sv"
TB="$ROOT/tests/rtl/plex_clk_refresh_meas_tb.cpp"
mkdir -p "$MDIR"

echo "=== test_plex_clk_refresh_meas_verilator EXECUTED ==="

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
test -f "$TOP" || { echo "FAIL missing $TOP" >&2; echo "true rc=2"; exit 2; }
test -f "$TB"  || { echo "FAIL missing $TB"  >&2; echo "true rc=2"; exit 2; }

set +e
"$RUN_VERILATOR" --cc --exe --build -sv \
  --Mdir "$MDIR" \
  --top-module plex_clk_refresh_meas_tb_top \
  -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  -DTB_MEAS_WIN=20000 \
  -DPRESENT_CLK_PIX_PLL=1 \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$TOP" "$RTL" "$TB"
v_rc=$?
set -e
echo "verilator_build true rc=$v_rc"
if [[ "$v_rc" -ne 0 ]]; then
  echo "FAIL verilator build" >&2
  echo "true rc=$v_rc"
  exit "$v_rc"
fi

BIN="$MDIR/Vplex_clk_refresh_meas_tb_top"
test -x "$BIN" || BIN="$MDIR/Vplex_clk_refresh_meas_tb_top.exe"
test -x "$BIN" || { echo "FAIL binary missing" >&2; exit 1; }

set +e
out=$("$BIN" 2>&1)
rc=$?
set -e
printf '%s\n' "$out"
echo "sim true rc=$rc"
echo "SIM_ARTIFACT=$BIN"

# GREEN + both NEG twins must execute (red-check corpus).
assert_sim_executed "plex_clk_refresh_meas" "$out" \
  "CASE EXECUTED" \
  "PASS POS_242HZ" \
  "PASS NEG_16HZ_TRAP" \
  "PASS NEG_EXACT24" \
  "PASS plex_clk_refresh_meas_tb all cases"

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL plex_clk_refresh_meas sim true rc=$rc" >&2
  echo "true rc=$rc"
  exit "$rc"
fi

# Explicit red-check wording for gate_false_green_guard corpus.
# NEG_16HZ proves 20 MHz same-clock trap fails product PASS.
# NEG_EXACT24 proves 24.000 Hz is NOT product PASS (distinguishes 240 vs 242).
if ! grep -q 'PASS NEG_16HZ_TRAP' <<<"$out"; then
  echo "FAIL plex_clk_refresh_meas red-check: NEG_16HZ_TRAP twin did not PASS" >&2
  exit 1
fi
if ! grep -q 'PASS NEG_EXACT24' <<<"$out"; then
  echo "FAIL plex_clk_refresh_meas red-check: NEG_EXACT24 twin did not PASS" >&2
  exit 1
fi
echo "OK plex_clk_refresh_meas red-check: NEG_16HZ_TRAP + NEG_EXACT24 twins PASS (true rc twin path)"
echo "PASS test_plex_clk_refresh_meas_verilator"
echo "true rc=0"
exit 0
