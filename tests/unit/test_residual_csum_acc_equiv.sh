#!/usr/bin/env bash
# residual_csum product path: ST_PLACE latches csum_acc (running XOR), not combo 16-fold.
# GREEN: Baseline multinal fixture observes residual_csum==0x14 at residual_place_pulse.
# RED:   FAULT_RES_CSUM_XOR1           — wrong value at place_pulse
# RED:   FAULT_RES_CSUM_ONE_CYCLE_DELAY — naive pipeline twin (latch in ST_DONE)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
WCAP_FIXTURE="$ROOT/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264"
RTL_COMMON=(
  tests/rtl/h264_multinal_stream_path_tb_top.sv
  fpga/Plex_MiSTer/rtl/stream_path.sv
  fpga/Plex_MiSTer/rtl/stream_ingest.sv
  fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv
  fpga/Plex_MiSTer/rtl/bitstream_fifo.sv
  fpga/Plex_MiSTer/rtl/nalu_scanner.sv
  fpga/Plex_MiSTer/rtl/sps_parser.sv
  fpga/Plex_MiSTer/rtl/pps_parser.sv
  fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv
  fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv
  fpga/Plex_MiSTer/rtl/h264_inter_pred.sv
  fpga/Plex_MiSTer/rtl/h264_deblock.sv
  fpga/Plex_MiSTer/rtl/h264_dpb.sv
  fpga/Plex_MiSTer/rtl/h264_mc_luma_qpel.sv
  fpga/Plex_MiSTer/rtl/h264_mc_chroma_epel.sv
  fpga/Plex_MiSTer/rtl/h264_mc_block.sv
  fpga/Plex_MiSTer/rtl/h264_hybrid_mb_own.sv
  fpga/Plex_MiSTer/rtl/decode_stub.sv
  fpga/Plex_MiSTer/rtl/h264_deblock_mb.sv
  fpga/Plex_MiSTer/rtl/h264_dpb_ref_commit.sv
  tests/rtl/residual_csum_place_pulse_tb.cpp
)

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing PASS without sim." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

cd "$ROOT"

build_one() {
  local mdir="$1"
  shift
  mkdir -p "$mdir"
  echo "RTL SIM residual_csum_acc: $mdir $*" >&2
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$mdir" \
    --top-module h264_multinal_stream_path_tb -Wno-fatal \
    -CFLAGS "-std=c++17 -O2" \
    "$@" \
    "${RTL_COMMON[@]}"
}

# --- math unit (no Verilator) ---
MATH_BIN="$ROOT/build/test_residual_csum_acc_math"
mkdir -p "$ROOT/build"
g++ -std=c++17 -O2 -I"$ROOT/host" \
  "$ROOT/tests/unit/test_residual_csum_acc_math.cpp" \
  -o "$MATH_BIN"
set +e
"$MATH_BIN"
MATH_RC=$?
set -e
echo "test_residual_csum_acc_math true rc=$MATH_RC"
if [[ "$MATH_RC" -ne 0 ]]; then
  exit "$MATH_RC"
fi

POS="$ROOT/build/verilator/residual_csum_acc_pos"
build_one "$POS"
set +e
"$POS/Vh264_multinal_stream_path_tb" "$WCAP_FIXTURE" 5 1 0x14
POS_RC=$?
set -e
echo "residual_csum_acc POS (csum_acc path) true rc=$POS_RC"
if [[ "$POS_RC" -ne 0 ]]; then
  exit "$POS_RC"
fi

XOR1="$ROOT/build/verilator/residual_csum_acc_fault_xor1"
build_one "$XOR1" -DFAULT_RES_CSUM_XOR1
set +e
"$XOR1/Vh264_multinal_stream_path_tb" "$WCAP_FIXTURE" 5 1 0x14 \
  >"$ROOT/build/residual_csum_acc_fault_xor1.log" 2>&1
XOR1_RC=$?
set -e
if [[ "$XOR1_RC" -eq 0 ]]; then
  cat "$ROOT/build/residual_csum_acc_fault_xor1.log" >&2
  echo "FAIL: FAULT_RES_CSUM_XOR1 unexpectedly passed 0x14" >&2
  exit 1
fi
grep -q "expected residual_csum was never observed" \
  "$ROOT/build/residual_csum_acc_fault_xor1.log"
echo "residual_csum_acc RED FAULT_RES_CSUM_XOR1 true rc=$XOR1_RC (expected fail)"

DELAY="$ROOT/build/verilator/residual_csum_acc_fault_delay"
build_one "$DELAY" -DFAULT_RES_CSUM_ONE_CYCLE_DELAY
set +e
"$DELAY/Vh264_multinal_stream_path_tb" "$WCAP_FIXTURE" 5 1 0x14 \
  >"$ROOT/build/residual_csum_acc_fault_delay.log" 2>&1
DELAY_RC=$?
set -e
if [[ "$DELAY_RC" -eq 0 ]]; then
  cat "$ROOT/build/residual_csum_acc_fault_delay.log" >&2
  echo "FAIL: FAULT_RES_CSUM_ONE_CYCLE_DELAY unexpectedly passed 0x14" >&2
  exit 1
fi
grep -q "expected residual_csum was never observed" \
  "$ROOT/build/residual_csum_acc_fault_delay.log"
echo "residual_csum_acc RED FAULT_RES_CSUM_ONE_CYCLE_DELAY true rc=$DELAY_RC (expected fail)"

echo "test_residual_csum_acc_equiv: PASS (math+POS+2 RED faults)"
