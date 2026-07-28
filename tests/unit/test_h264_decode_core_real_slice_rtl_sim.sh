#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_decode_core real-slice simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

TOP="$ROOT/tests/rtl/h264_decode_core_p16z_tb.sv"
TB="$ROOT/tests/rtl/h264_decode_core_real_slice_tb.cpp"
SLICE="$ROOT/tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
BUILD="$ROOT/build/verilator/h264_decode_core_real_slice"
BUILD_SWAP_CHROMA="$ROOT/build/verilator/h264_decode_core_real_slice_swap_chroma_read"
RTL=(
  "$RTL_DIR/h264_syntax_primitives.sv"
  "$RTL_DIR/h264_cavlc_residual.sv"
  "$RTL_DIR/h264_iq_idct_4x4.sv"
  "$RTL_DIR/h264_inter_pred.sv"
  "$RTL_DIR/h264_decode_core.sv"
  "$RTL_DIR/h264_dpb.sv"
)
for f in "$TOP" "$TB" "$SLICE" "${RTL[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done

build_and_run() {
  local build_dir="$1"
  local define_arg="$2"
  local bin="$build_dir/Vh264_decode_core_p16z_tb"
  mkdir -p "$build_dir"
  rm -f "$bin"
  echo "RTL SIM: using $VERILATOR_VERSION (h264_decode_core real-content slice${define_arg:+ $define_arg})" >&2
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build_dir" \
    --top-module h264_decode_core_p16z_tb -Wno-fatal -GFRAME_W=624 -GFRAME_H=480 $define_arg \
    -CFLAGS "-std=c++17 -O2" \
    "$TOP" "${RTL[@]}" "$TB"
  test -x "$bin"
  MPLEX_REAL_SLICE="$SLICE" "$bin"
}

build_and_run "$BUILD" ""

set +e
SWAP_OUT="$(build_and_run "$BUILD_SWAP_CHROMA" "+define+H264_DECODE_CORE_FAULT_SWAP_CHROMA_READ" 2>&1)"
SWAP_RC=$?
set -e
printf '%s\n' "$SWAP_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_real_slice_swap_chroma_read "$SWAP_RC" <<<"$SWAP_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$SWAP_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core real-slice red-check: swapped U/V chroma read failed real-content scoreboard"
