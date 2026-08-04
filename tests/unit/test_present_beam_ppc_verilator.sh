#!/usr/bin/env bash
# RED-before-GREEN: present_beam_ppc PPC=2 vs PPC=1 cycle density.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_ppc.sv"
TOP="$ROOT/tests/rtl/present_beam_ppc_tb_top.sv"
TB="$ROOT/tests/rtl/present_beam_ppc_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
BUILD2="$ROOT/build/verilator/present_beam_ppc2"
BUILD1="$ROOT/build/verilator/present_beam_ppc1"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  exit "$VERILATOR_RC"
fi

build_ppc() {
  local mdir="$1"
  local ppc="$2"
  mkdir -p "$mdir"
  # Override default parameter via top-level -G
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$mdir" \
    --top-module present_beam_ppc_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2" \
    -GPX_PER_CLK="${ppc}" \
    "$RTL" "$TOP" "$TB"
}

echo "RTL SIM: present_beam_ppc using $VERILATOR_VERSION" >&2
build_ppc "$BUILD2" 2
build_ppc "$BUILD1" 1

EXE2="$BUILD2/Vpresent_beam_ppc_tb_top"
EXE1="$BUILD1/Vpresent_beam_ppc_tb_top"

set +e
OUT2="$("$EXE2" 2>&1)"
RC2=$?
OUT1="$("$EXE1" 2>&1)"
RC1=$?
set -e
printf '%s\n' "$OUT2"
echo "beam_ppc2 true rc=$RC2"
printf '%s\n' "$OUT1"
echo "beam_ppc1 true rc=$RC1"

if [[ "$RC2" -ne 0 ]]; then
  echo "FAIL: PPC=2 beam" >&2
  exit "$RC2"
fi
if [[ "$RC1" -ne 0 ]]; then
  echo "FAIL: PPC=1 beam baseline" >&2
  exit "$RC1"
fi

# RED: PPC=1 must take ~2× ce cycles of PPC=2 for same line (825 vs 1650).
CE2="$(printf '%s\n' "$OUT2" | sed -n 's/.*ce_cycles_line0=\([0-9]*\).*/\1/p' | head -1)"
CE1="$(printf '%s\n' "$OUT1" | sed -n 's/.*ce_cycles_line0=\([0-9]*\).*/\1/p' | head -1)"
echo "COMPARE ce_ppc2=$CE2 ce_ppc1=$CE1"
if [[ -z "$CE2" || -z "$CE1" ]]; then
  echo "FAIL: missing ce_cycles parse" >&2
  exit 1
fi
if [[ "$CE1" -le "$CE2" ]]; then
  echo "FAIL RED: expected PPC1 cycles > PPC2 cycles ($CE1 <= $CE2)" >&2
  exit 1
fi
# Exact: 1650/1=1650, 1650/2=825
if [[ "$CE2" -ne 825 ]]; then
  echo "FAIL: expected PPC2 ce=825 got $CE2" >&2
  exit 1
fi
if [[ "$CE1" -ne 1650 ]]; then
  echo "FAIL: expected PPC1 ce=1650 got $CE1" >&2
  exit 1
fi
echo "RED proof: PPC1 denser timeline ($CE1 > $CE2) — PPC=1 cannot close 29.7 Mpix/s at 20 MHz"
echo "PRESENT_BEAM_PPC gate PASS"
