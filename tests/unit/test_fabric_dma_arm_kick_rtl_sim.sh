#!/usr/bin/env bash
# Verilator sim: fabric_dma_arm_kick_tb (POS accept + NEG misalign).
# Soft-skip≠PASS. true rc direct. assert_sim_executed required.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/fabric_dma_arm_kick.sv"
TB="$ROOT/tests/rtl/fabric_dma_arm_kick_tb.sv"
BDIR="$ROOT/build/verilator/fabric_dma_arm_kick"
mkdir -p "$BDIR"

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

echo "=== test_fabric_dma_arm_kick_rtl_sim EXECUTED ==="
echo "PRE_REGISTER: POS start+accept on aligned kick; NEG no-start on misalign"
echo "M10K arm_kick=0 layout=N/A (regs)"

if [[ ! -f "$RTL" || ! -f "$TB" ]]; then
  echo "FAIL missing RTL/TB" >&2
  exit 1
fi

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing SKIP-as-pass" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi
echo "RTL SIM: using $VERILATOR_VERSION" >&2

# Pure-SV TB needs --timing (delay/# in always/initial).
"$RUN_VERILATOR" --binary --timing -Wno-fatal \
  --top-module fabric_dma_arm_kick_tb \
  -Mdir "$BDIR" -o fabric_dma_arm_kick_sim \
  "$RTL" "$TB"

set +e
OUT="$("$BDIR/fabric_dma_arm_kick_sim" 2>&1)"
RRC=$?
set -e
printf '%s\n' "$OUT"
echo "sim true_rc=$RRC"
if [[ "$RRC" -ne 0 ]]; then
  echo "FAIL sim rc=$RRC" >&2
  exit "$RRC"
fi
assert_sim_executed "fabric_dma_arm_kick" "$OUT" \
  "CASE fabric_dma_arm_kick_tb EXECUTED" \
  "PASS fabric_dma_arm_kick_tb pos_accept+neg_misalign"

echo "PASS test_fabric_dma_arm_kick_rtl_sim"
exit 0
