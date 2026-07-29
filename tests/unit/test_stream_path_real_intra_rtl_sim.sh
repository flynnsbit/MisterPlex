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
mkdir -p "$BUILD"

COMMON=(
  "$TOP"
  "$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/stream_ingest.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bitstream_prefetch.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/bitstream_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/nalu_scanner.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_rbsp_window.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_i_mb_feed.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/sps_parser.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/pps_parser.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/slice_hdr_parser.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/decode_stub.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_intra_pred.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_intra_nb_ctx.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_decode_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_decode_core.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_pred.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_pskip_mv.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_part.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv"
  "$TB"
)

python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
stream = (root / "fpga/Plex_MiSTer/rtl/stream_path.sv").read_text()
core = (root / "fpga/Plex_MiSTer/rtl/h264_decode_core.sv").read_text()
if "h264_decode_core" not in stream:
    raise SystemExit("FAIL real-intra topology: stream_path does not instantiate h264_decode_core")
if "h264_decode_top" in stream:
    raise SystemExit("FAIL real-intra topology: stream_path still instantiates h264_decode_top as a subtree swap")
if "h264_decode_top" not in core:
    raise SystemExit("FAIL real-intra topology: h264_decode_core does not instantiate h264_decode_top sub-engine")
PY

python3 "$ROOT/scripts/check_rtl_module_instantiations.py" >/dev/null

echo "RTL SIM: using $VERILATOR_VERSION (stream_path core-rooted intra topology)" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" --top-module stream_path_recon_integration_tb_top \
  -Wno-fatal -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC +define+DECODE_REAL_INTRA=1 \
  -CFLAGS "-std=c++17 -O2" "${COMMON[@]}"

"$BUILD/Vstream_path_recon_integration_tb_top" "$BITSTREAM"
echo "OK real-intra topology gate: stream_path uses h264_decode_core; h264_decode_top is core sub-engine"
