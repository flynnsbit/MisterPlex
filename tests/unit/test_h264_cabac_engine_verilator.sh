#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
TRACE="${CABAC_TRACE:-$ROOT/tests/fixtures/p3_host_recon/cabac_trace_i0_ffmpeg.log}"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_cabac_engine.sv"
TOP="$ROOT/tests/rtl/h264_cabac_engine_tb_top.sv"
TB="$ROOT/tests/rtl/h264_cabac_engine_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_cabac_engine real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite-20260726 or set VERILATOR=/path/to/verilator.
SKIP
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

if [[ ! -s "$TRACE" ]]; then
  echo "RTL SIM ERROR: missing CABAC trace $TRACE; h264_cabac_engine real RTL simulation was NOT run." >&2
  exit 2
fi

build_one() {
  local name="$1"
  local extra_define="$2"
  local build_dir="$ROOT/build/verilator/$name"
  mkdir -p "$build_dir"
  echo "RTL SIM: using $VERILATOR_VERSION ($name)" >&2
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build_dir" \
    --top-module h264_cabac_engine_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2" \
    $extra_define \
    "$RTL" "$TOP" "$TB"
}

build_one h264_cabac_engine_neg -DCABAC_NEGATIVE_TEST
NEG_EXE="$ROOT/build/verilator/h264_cabac_engine_neg/Vh264_cabac_engine_tb_top"
set +e
"$NEG_EXE" "$TRACE" > "$ROOT/build/h264_cabac_engine_negative.log" 2>&1
NEG_RC=$?
set -e
if [[ "$NEG_RC" -eq 0 ]]; then
  echo "RTL SIM ERROR: negative CABAC perturbation unexpectedly passed" >&2
  cat "$ROOT/build/h264_cabac_engine_negative.log" >&2
  exit 1
fi
echo "RTL SIM RED proof: CABAC_NEGATIVE_TEST failed as expected (rc=$NEG_RC)" >&2
sed -n '1,4p' "$ROOT/build/h264_cabac_engine_negative.log" >&2

build_one h264_cabac_engine_pos ''
POS_EXE="$ROOT/build/verilator/h264_cabac_engine_pos/Vh264_cabac_engine_tb_top"
"$POS_EXE" "$TRACE"
