#!/usr/bin/env bash
# Verilator gate: present_nn_linebuf_scaler pixel-for-pixel + cycle measure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/present_nn_linebuf_scaler.sv"
TOP="$ROOT/tests/rtl/present_nn_linebuf_scaler_tb_top.sv"
TB="$ROOT/tests/rtl/present_nn_linebuf_scaler_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
BUILD_DIR="$ROOT/build/verilator/present_nn_linebuf_scaler"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; nn_linebuf_scaler RTL sim NOT run." >&2
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    exit 3
  fi
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

mkdir -p "$BUILD_DIR"
echo "RTL SIM: $VERILATOR_VERSION (present_nn_linebuf_scaler)" >&2
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DIR" \
  --top-module present_nn_linebuf_scaler_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL" "$TOP" "$TB"

EXE="$BUILD_DIR/Vpresent_nn_linebuf_scaler_tb_top"
# shellcheck source=tests/unit/lib_rtl_sim_gate.sh
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
set +e
OUT="$("$EXE" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
echo "present_nn_linebuf_scaler true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  exit "$RC"
fi
assert_sim_executed "present_nn_linebuf_scaler" "$OUT" "Verilator PASS"
echo "present_nn_linebuf_scaler Verilator PASS"
