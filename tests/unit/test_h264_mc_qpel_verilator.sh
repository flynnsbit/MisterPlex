#!/usr/bin/env bash
# REAL RTL SIMULATION of the serialized motion-compensation interpolators.
#
# The luma engine went 89,888 -> 441 ALUTs and the chroma engine was refactored
# from a four-term product into two separable passes.  Both preserve the
# algorithm on paper; only executing the RTL shows whether the SystemVerilog
# implements it.  This bench runs the actual modules and compares every output
# sample against an independent H.264 8.4.2.2.1 / 8.4.2.2.2 golden.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL_L="$ROOT/fpga/Plex_MiSTer/rtl/h264_mc_luma_qpel.sv"
RTL_C="$ROOT/fpga/Plex_MiSTer/rtl/h264_mc_chroma_epel.sv"
TOP="$ROOT/tests/rtl/h264_mc_qpel_tb_top.sv"
TB="$ROOT/tests/rtl/h264_mc_qpel_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; MC interpolator real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite-20260726 or set VERILATOR=/path/to/verilator.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    echo "A skipped RTL gate is NOT a pass. Set ALLOW_MISSING_VERILATOR=1 only if you accept that RTL was never verified." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

build_one() {
  local name="$1"
  local extra_define="$2"
  local build_dir="$ROOT/build/verilator/$name"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"
  echo "RTL SIM: using $VERILATOR_VERSION ($name)" >&2
  OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build_dir" \
    --top-module h264_mc_qpel_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2 $extra_define" \
    "$RTL_L" "$RTL_C" "$TOP" "$TB"
}

# RED proof first: perturbing the golden must make the run fail, otherwise the
# comparison is vacuous and a green result means nothing.
build_one h264_mc_qpel_neg '-DMC_NEGATIVE_TEST'
NEG_EXE="$ROOT/build/verilator/h264_mc_qpel_neg/Vh264_mc_qpel_tb_top"
set +e
"$NEG_EXE" > "$ROOT/build/h264_mc_qpel_negative.log" 2>&1
NEG_RC=$?
set -e
if [[ "$NEG_RC" -eq 0 ]]; then
  echo "RTL SIM ERROR: MC_NEGATIVE_TEST perturbation unexpectedly passed" >&2
  tail -5 "$ROOT/build/h264_mc_qpel_negative.log" >&2
  exit 1
fi
echo "RTL SIM RED proof: MC_NEGATIVE_TEST failed as expected (rc=$NEG_RC)" >&2
grep -m3 MISMATCH "$ROOT/build/h264_mc_qpel_negative.log" >&2 || true

build_one h264_mc_qpel_pos ''
"$ROOT/build/verilator/h264_mc_qpel_pos/Vh264_mc_qpel_tb_top"
