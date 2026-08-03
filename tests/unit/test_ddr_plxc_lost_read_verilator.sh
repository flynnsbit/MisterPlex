#!/usr/bin/env bash
# Store-like m0 vs sticky m3_want: launch-edge lost-read must not hang WAIT.
# Product FAULT_LOST_READ=0 → hang=0. Red twin FAULT=1 must REPRO hang>0.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not found or broken; refusing to PASS without simulation." >&2
  exit 3
fi

echo "RTL SIM: using $VERILATOR_VERSION" >&2
RTL=(
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter_plxc.sv"
  "$ROOT/tests/rtl/ddr_plxc_lost_read_tb_top.sv"
  "$ROOT/tests/rtl/ddr_plxc_lost_read_tb.cpp"
)

build_one() {
  local fault="$1"
  local bdir="$ROOT/build/verilator/ddr_plxc_lost_read_f${fault}"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
    --Mdir "$bdir" \
    --top-module ddr_plxc_lost_read_tb_top \
    -GFAULT_LOST_READ="${fault}" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2" \
    "${RTL[@]}" >&2
  if [[ ! -x "$bdir/Vddr_plxc_lost_read_tb_top" ]]; then
    echo "BUILD FAIL fault=${fault}" >&2
    return 1
  fi
  printf '%s\n' "$bdir/Vddr_plxc_lost_read_tb_top"
}

FAIL=0

echo "=== PRODUCT FAULT_LOST_READ=0 ===" >&2
EXE0="$(build_one 0)"
set +e
OUT0="$("$EXE0" 2>&1)"
RC0=$?
set -e
printf '%s\n' "$OUT0"
echo "product lost_read true rc=$RC0"
if [[ "$RC0" -ne 0 ]]; then
  echo "FAIL product lost-read" >&2
  FAIL=1
fi
if ! printf '%s\n' "$OUT0" | grep -q 'fill_hang=0'; then
  echo "FAIL product expected fill_hang=0" >&2
  FAIL=1
fi

echo "=== FAULT twin FAULT_LOST_READ=1 ===" >&2
EXE1="$(build_one 1)"
set +e
OUT1="$("$EXE1" 2>&1)"
RC1=$?
set -e
printf '%s\n' "$OUT1"
echo "fault lost_read exe_rc=$RC1 (expect hang)"
if printf '%s\n' "$OUT1" | grep -qE 'fill_hang=[1-9]|REPRO lost-read-hang'; then
  echo "REPRO fault-lost-read hang observed"
else
  echo "FAIL fault twin did not hang (race not reproduced)" >&2
  FAIL=1
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "ddr_plxc_lost_read true rc=1"
  exit 1
fi
echo "ddr_plxc_lost_read ALL PASS (product+fault twin)"
echo "ddr_plxc_lost_read_sim true rc=0"
exit 0
