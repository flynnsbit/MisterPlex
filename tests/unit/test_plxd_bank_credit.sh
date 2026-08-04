#!/usr/bin/env bash
# plxd_bank_credit Verilator gate — DMA/zero-copy ownership scoreboard.
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
BUILD="$ROOT/build/verilator/plxd_bank_credit"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl"
mkdir -p "$BUILD"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit 3
fi

$RUN_VERILATOR -sv -cc --exe --build -Mdir "$BUILD" \
  -CFLAGS "-std=c++17 -O2" \
  -Wno-WIDTH -Wno-SELRANGE -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-UNSIGNED \
  -I"$RTL" \
  --top-module plxd_bank_credit_tb_top \
  "$TB/plxd_bank_credit_tb_top.sv" \
  "$RTL/plxd_bank_credit.sv" \
  "$TB/plxd_bank_credit_tb.cpp" \
  -o Vplxd_bank_credit_tb_top

set +e
OUT="$("$BUILD/Vplxd_bank_credit_tb_top" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
assert_sim_executed "plxd_bank_credit" "$OUT" \
  "PASS credit multi-present" \
  "PASS credit NEG:" \
  "PASS plxd_bank_credit"
exit "$RC"
