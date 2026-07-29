#!/usr/bin/env bash
# P-frame product path with ffmpeg reference injection (tb_mem and optional BRAM).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
  echo "REFUSE: ALLOW_MISSING_VERILATOR=1 is not a pass" >&2
  exit 2
fi
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
export OSS_CAD_SUITE
V="$ROOT/scripts/run_verilator.sh"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
TOP="$ROOT/tests/rtl/h264_pframe_ref_inject_tb.sv"
TB="$ROOT/tests/rtl/h264_pframe_ref_inject_tb.cpp"
ANNEXB="$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264"
I420="$ROOT/.scratch/pframe_inject/nodeblock_320x240.i420"
mkdir -p "$ROOT/.scratch/pframe_inject"

command -v ffmpeg >/dev/null || { echo "FAIL: ffmpeg required" >&2; exit 2; }
# skip_loop_filter: our DPB is pre-deblock; match that on the golden planes.
if [[ ! -f "$I420" ]]; then
  ffmpeg -y -hide_banner -loglevel error -skip_loop_filter all \
    -i "$ANNEXB" -frames:v 3 -f rawvideo -pix_fmt yuv420p "$I420"
fi
export MPLEX_I420="$I420"

RTL=(
  "$RTL_DIR/h264_cavlc_residual.sv"
  "$RTL_DIR/h264_iq_idct_4x4.sv"
  "$RTL_DIR/h264_intra_pred.sv"
  "$RTL_DIR/h264_intra_nb_ctx.sv"
  "$RTL_DIR/h264_decode_top.sv"
  "$RTL_DIR/h264_inter_pred.sv"
  "$RTL_DIR/h264_deblock.sv"
  "$RTL_DIR/h264_decode_core.sv"
  "$RTL_DIR/mb_sample_ram.sv"
  "$RTL_DIR/h264_dpb.sv"
  "$RTL_DIR/h264_transform_dc.sv"
  "$RTL_DIR/h264_mc_block.sv"
  "$RTL_DIR/h264_mc_luma_qpel.sv"
  "$RTL_DIR/h264_mc_chroma_epel.sv"
  "$RTL_DIR/h264_deblock_mb.sv"
  "$RTL_DIR/h264_perf_counters.sv"
  "$RTL_DIR/h264_dpb_bram_ref.sv"
  "$RTL_DIR/h264_dpb_ddr_wr.sv"
  "$RTL_DIR/h264_dpb_ddr_rd.sv"
  "$RTL_DIR/h264_dpb_ddr.sv"
)

run_one() {
  local tag="$1"
  local define="$2"
  local cdefine="$3"
  local build="$ROOT/build/verilator/h264_pframe_ref_inject_${tag}"
  rm -rf "$build"
  mkdir -p "$build"
  # shellcheck disable=SC2086
  $V --cc --exe --build -sv -O2 --top-module h264_pframe_ref_inject_tb \
    -Mdir "$build" -Wno-fatal \
    -CFLAGS "-std=c++17 -O2 $cdefine" \
    $define \
    "$TOP" "${RTL[@]}" "$TB"
  echo "=== RUN $tag ==="
  "$build/Vh264_pframe_ref_inject_tb"
}

echo "RTL SIM: pframe ref-inject (tb_mem path)"
run_one tbmem "" ""

echo "RTL SIM: pframe ref-inject (BRAM_REF path)"
run_one bram "-GUSE_BRAM_DPB=1" "-DUSE_BRAM_DPB"
