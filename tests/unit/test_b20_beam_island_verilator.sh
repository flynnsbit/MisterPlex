#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
OUT="$ROOT/build/verilator/b20_beam_island"
mkdir -p "$OUT"

set +e
VER="$("$RV" --version 2>&1)"; VRC=$?
set -e
if [[ "$VRC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
fi
echo "RTL SIM: using $VER" >&2

build_one() {
  local tag="$1"; shift
  local d="$OUT/$tag"
  rm -rf "$d"; mkdir -p "$d"
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RV" --cc --exe --build \
    +incdir+$ROOT/fpga/Plex_MiSTer/rtl \
    --Mdir "$d" --top-module b20_beam_island_tb_top \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    "$@" \
    "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv" \
    "$ROOT/tests/rtl/b20_beam_island_tb_top.sv" \
    "$ROOT/tests/rtl/b20_beam_island_tb.cpp" \
    -o Vb20_beam_island_tb_top >&2
  printf '%s\n' "$d/Vb20_beam_island_tb_top"
}

EXE="$(build_one product -CFLAGS "-std=c++17 -O2")"
set +e
OUTP="$("$EXE" 2>&1)"; PRC=$?
set -e
printf '%s\n' "$OUTP"
echo "b20_beam_island_product true rc=$PRC"
if [[ "$PRC" -ne 0 ]] || ! printf '%s\n' "$OUTP" | grep -q 'PASS no island'; then
  echo "FAIL product b20 beam island" >&2
  exit 1
fi

EXF="$(build_one fault \
  +define+FAULT_B20_NO_BEAM_FEEDFORWARD +define+FAULT_B20_NO_BEAM_HOLD \
  -CFLAGS "-std=c++17 -O2 -DFAULT_B20_NO_BEAM_FEEDFORWARD -DFAULT_B20_NO_BEAM_HOLD")"
set +e
OUTF="$("$EXF" 2>&1)"; FRC=$?
set -e
printf '%s\n' "$OUTF"
echo "b20_beam_island_fault true rc=$FRC"
if [[ "$FRC" -ne 2 ]] || ! printf '%s\n' "$OUTF" | grep -q 'REPRO island'; then
  echo "FAIL red twin did not REPRO island" >&2
  exit 1
fi

echo "PASS test_b20_beam_island product+REPRO"
exit 0
