#!/usr/bin/env bash
# RED/GREEN Verilator gate for present_nn_linebuf_scaler.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/present_nn_linebuf_scaler.sv"
TOP="$ROOT/tests/rtl/present_nn_linebuf_scaler_tb_top.sv"
TB="$ROOT/tests/rtl/present_nn_linebuf_scaler_tb.cpp"
GEOM="$ROOT/fpga/Plex_MiSTer/rtl/plex_m10k_geom.svh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed rc=$VERILATOR_RC" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

build_run() {
  local name="$1"
  local cdef="$2"
  local build_dir="$ROOT/build/verilator/$name"
  mkdir -p "$build_dir"
  echo "RTL SIM: $VERILATOR_VERSION ($name)" >&2
  # shellcheck disable=SC2086
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build_dir" \
    --top-module present_nn_linebuf_scaler_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2 ${cdef}" \
    -I"$ROOT/fpga/Plex_MiSTer/rtl" \
    "$RTL" "$TOP" "$TB"
  "$build_dir/Vpresent_nn_linebuf_scaler_tb_top"
  return $?
}

# NEGATIVE first: fault must diverge (tb returns 0 on divergence under ifdef)
set +e
build_run present_nn_lb_neg "-DPRESENT_NN_LB_FAULT_FLOOR_SCALE"
neg_rc=$?
set -e
if [[ "$neg_rc" -ne 0 ]]; then
  echo "FAIL: negative FLOOR_SCALE path rc=$neg_rc (want 0 = diverged)" >&2
  exit "$neg_rc"
fi
echo "RTL SIM RED proof: FLOOR_SCALE diverged (wrapper ok)"

set +e
build_run present_nn_lb_pos ""
pos_rc=$?
set -e
echo "present_nn_linebuf_scaler_pos true rc=$pos_rc"
exit "$pos_rc"
