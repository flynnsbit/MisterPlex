#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing to PASS without real-intra simulation." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BITSTREAM="$ROOT/tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264"
TOP="$ROOT/tests/rtl/stream_path_recon_integration_tb_top.sv"
TB="$ROOT/tests/rtl/stream_path_real_intra_tb.cpp"
BUILD="$ROOT/build/verilator/stream_path_real_intra"
BUILD_FAULT="$ROOT/build/verilator/stream_path_real_intra_fault"
mkdir -p "$BUILD" "$BUILD_FAULT"

COMMON=(
  "$TOP"
  "$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/stream_ingest.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/bitstream_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/nalu_scanner.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/sps_parser.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/pps_parser.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/decode_stub.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_intra_pred.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_decode_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_pred.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv"
  "$TB"
)

echo "RTL SIM: using $VERILATOR_VERSION (stream_path real intra)" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" --top-module stream_path_recon_integration_tb_top \
  -Wno-fatal -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC +define+DECODE_REAL_INTRA=1 \
  -CFLAGS "-std=c++17 -O2" "${COMMON[@]}"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" --top-module stream_path_recon_integration_tb_top \
  -Wno-fatal -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC +define+DECODE_REAL_INTRA=1 +define+STREAM_PATH_REAL_INTRA_FAULT_STUB_PIXEL \
  -CFLAGS "-std=c++17 -O2" "${COMMON[@]}"

"$BUILD/Vstream_path_recon_integration_tb_top" "$BITSTREAM"
set +e
FAULT_OUT="$($BUILD_FAULT/Vstream_path_recon_integration_tb_top "$BITSTREAM" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL real-intra mutation: forced placeholder luma unexpectedly passed" >&2
  exit 1
fi
if ! grep -q "displayed first 4x4 stayed at placeholder gray 128" <<<"$FAULT_OUT"; then
  echo "FAIL real-intra mutation: failure did not name placeholder-gray comparison" >&2
  exit 1
fi
echo "OK real-intra mutation red-check: forced placeholder luma rejected"
