#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${1:-}" == --matrix && $# == 2 ]]; then
  echo "PUBLISH_VARIANT baseline"
  bash "${BASH_SOURCE[0]}" --publisher-source "$2"
  echo "PUBLISH_VARIANT default"
  bash "${BASH_SOURCE[0]}"
  echo "PUBLISH_VARIANT pipeline"
  bash "${BASH_SOURCE[0]}" --pipeline
  exit
fi
BUILD="$ROOT/build/verilator/fpga_video_publish"
PUBLISHER="$ROOT/fpga/Plex_MiSTer/rtl/fpga_video_publish.sv"
DEFINES=()
while (($#)); do
  case "$1" in
    --pipeline) DEFINES+=("-DPLEX_NATIVE_COPY_PIPELINE=1"); BUILD+="-pipeline"; shift ;;
    --publisher-source) PUBLISHER="$(realpath "$2")"; BUILD+="-baseline"; shift 2 ;;
    *) echo "Unsupported publisher selector: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
INPUTS=(
  "$ROOT/tests/rtl/fpga_video_publish_tb_top.sv"
  "$ROOT/tests/rtl/fpga_video_publish_tb.cpp"
  "$PUBLISHER"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_transport_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/mplex_hold_lcell.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/source_aspect_ack.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/playback_overlay_plane.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_performance_clock.svh"
  "$ROOT/tests/frozen-host/ddr_bitstream_ring.hpp"
  "$ROOT/tests/frozen-host/mailbox_abi_spec.hpp"
)
sha256sum "${INPUTS[@]}" > "$BUILD/inputs.sha256"
"$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 1 \
  --Mdir "$BUILD" --top-module fpga_video_publish_tb -Wno-fatal \
  "${DEFINES[@]}" \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/tests/frozen-host" \
  "$ROOT/tests/rtl/fpga_video_publish_tb_top.sv" \
  "$PUBLISHER" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_transport_mux.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/mplex_hold_lcell.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/source_aspect_ack.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/playback_overlay_plane.sv" \
  "$ROOT/tests/rtl/fpga_video_publish_tb.cpp"
"$BUILD/Vfpga_video_publish_tb"
"$BUILD/Vfpga_video_publish_tb" copy-contract
sha256sum --check --status "$BUILD/inputs.sha256"
sha256sum "$BUILD/Vfpga_video_publish_tb" > "$BUILD/binary.sha256"
