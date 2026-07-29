#!/usr/bin/env bash
# Execute transform/dequant RTL vs SPEC/FFmpeg golden (qP 0..51).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
TOP="$ROOT/tests/rtl/h264_transform_dequant_tb_top.sv"
TB="$ROOT/tests/rtl/h264_transform_dequant_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing PASS without simulation." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

build_one() {
  local name="$1"
  local extra_define="$2"
  local build_dir="$ROOT/build/verilator/$name"
  mkdir -p "$build_dir"
  echo "RTL SIM: using $VERILATOR_VERSION ($name)" >&2
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build_dir" \
    --top-module h264_transform_dequant_tb_top \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2 -I$ROOT/host -I$ROOT/tests/rtl" \
    $extra_define \
    "$RTL_DIR/h264_transform_dc.sv" \
    "$RTL_DIR/h264_iq_idct_4x4.sv" \
    "$RTL_DIR/h264_dpb.sv" \
    "$TOP" "$TB"
}

build_one h264_transform_dequant_neg -DTRANSFORM_NEGATIVE_TEST
NEG_EXE="$ROOT/build/verilator/h264_transform_dequant_neg/Vh264_transform_dequant_tb_top"
mkdir -p "$ROOT/build"
set +e
"$NEG_EXE" > "$ROOT/build/h264_transform_dequant_negative.log" 2>&1
NEG_RC=$?
set -e
if [[ "$NEG_RC" -eq 0 ]]; then
  echo "RTL SIM ERROR: perturbed transform datapath unexpectedly passed" >&2
  cat "$ROOT/build/h264_transform_dequant_negative.log" >&2
  exit 1
fi
echo "RTL SIM RED proof: TRANSFORM_NEGATIVE_TEST failed as expected (rc=$NEG_RC)" >&2
sed -n '1,5p' "$ROOT/build/h264_transform_dequant_negative.log" >&2

build_one h264_transform_dequant_pos ''
"$ROOT/build/verilator/h264_transform_dequant_pos/Vh264_transform_dequant_tb_top"
