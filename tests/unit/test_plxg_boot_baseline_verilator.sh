#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
OUT="$ROOT/build/verilator/plxg_boot_baseline"
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
    --Mdir "$d" --top-module plxg_boot_baseline_tb_top \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    "$@" \
    "$ROOT/fpga/Plex_MiSTer/rtl/plxg_ddr_poller.sv" \
    "$ROOT/tests/rtl/plxg_boot_baseline_tb_top.sv" \
    "$ROOT/tests/rtl/plxg_boot_baseline_tb.cpp" \
    -o Vplxg_boot_baseline_tb_top >&2
  printf '%s\n' "$d/Vplxg_boot_baseline_tb_top"
}

EXE="$(build_one product -CFLAGS "-std=c++17 -O2")"
set +e
OUTP="$(PLXG_BASELINE_MODE=retained "$EXE" 2>&1)"; PRC=$?
set -e
printf '%s\n' "$OUTP"
echo "plxg_boot_baseline_product true rc=$PRC"
if [[ "$PRC" -ne 0 ]] || ! printf '%s\n' "$OUTP" | grep -q 'PASS boot baseline'; then
  echo "FAIL product boot baseline" >&2
  exit 1
fi
if ! printf '%s\n' "$OUTP" | grep -q 'PASS fresh zero'; then
  echo "FAIL product fresh-zero one-publish" >&2
  exit 1
fi

EXF="$(build_one fault +define+FAULT_PLXG_NO_BASELINE -CFLAGS "-std=c++17 -O2 -DFAULT_PLXG_NO_BASELINE")"
set +e
OUTF="$(PLXG_BASELINE_MODE=retained "$EXF" 2>&1)"; FRC=$?
set -e
printf '%s\n' "$OUTF"
echo "plxg_boot_baseline_fault true rc=$FRC"
if [[ "$FRC" -ne 2 ]] || ! printf '%s\n' "$OUTF" | grep -q 'REPRO retained-promoted'; then
  echo "FAIL red twin did not REPRO" >&2
  exit 1
fi

EXE2="$(build_one fault_empty +define+FAULT_PLXG_EMPTY_NO_BASELINE -CFLAGS "-std=c++17 -O2 -DFAULT_PLXG_EMPTY_NO_BASELINE")"
set +e
OUTFE="$(PLXG_BASELINE_MODE=fresh "$EXE2" 2>&1)"; FERC=$?
set -e
printf '%s\n' "$OUTFE"
echo "plxg_boot_baseline_fault_empty true rc=$FERC"
if [[ "$FERC" -ne 2 ]] || ! printf '%s\n' "$OUTFE" | grep -q 'REPRO empty-no-baseline'; then
  echo "FAIL empty-no-baseline red twin did not REPRO" >&2
  exit 1
fi
echo "PASS test_plxg_boot_baseline product+REPROs (retained+fresh+empty)"
exit 0
