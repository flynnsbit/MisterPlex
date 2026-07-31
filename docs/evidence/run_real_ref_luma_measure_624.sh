#!/usr/bin/env bash
# Focused REAL_REF + luma progress measure (sv-traverse lane).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
BITSTREAM="${FULL_FRAME_BITSTREAM:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264}"
TOP="$ROOT/tests/rtl/stream_path_full_frame_tb_top.sv"
TB="$ROOT/tests/rtl/stream_path_full_frame_tb.cpp"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
PRODUCT_RTL=(
  stream_path.sv stream_ingest.sv ddr_bitstream_reader.sv bitstream_fifo.sv
  nalu_scanner.sv sps_parser.sv pps_parser.sv slice_hdr_parser.sv
  h264_iq_idct_4x4.sv h264_inter_pred.sv h264_deblock.sv h264_dpb.sv
  decode_stub.sv h264_p_mb_traverse.sv h264_byte_ram_sp.sv h264_i16_dc_hadamard.sv h264_i16_dc_hadamard_serial.sv h264_dequant4x4_serial.sv
  h264_i_res_recon_sink.sv h264_intra_pred.sv h264_recon_frame_store.sv
  h264_cavlc_residual.sv
)
RTL_ARGS=()
for f in "${PRODUCT_RTL[@]}"; do RTL_ARGS+=("$RTL_DIR/$f"); done

SOURCE_SHA=$(sha256sum "$BITSTREAM" | awk '{print $1}')
WIDTH=624; HEIGHT=480
SEQUENCE="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_624x480_sequence_v1.json"
GOLDEN_PLANES="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_i420.yuv"
GOLDEN_MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_frame_planes_v1.json"

BUILD_REAL="$ROOT/build/verilator/stream_path_full_frame_real_ref_624"
REAL_REF_DIR="$ROOT/build/p3_full_frame_real_ref_624"
mkdir -p "$BUILD_REAL" "$REAL_REF_DIR"
REAL_META="$REAL_REF_DIR/native_inter_metadata.json"
REAL_CAND="$REAL_REF_DIR/native_inter_candidate.i420"
REAL_SCORE="$REAL_REF_DIR/native_inter_candidate_score.json"
REAL_COMPARE="$REAL_REF_DIR/frame_planes_compare.json"

SRC_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY=""; git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet || DIRTY="-dirty"
echo "REAL_REF_MEASURE source_sha=${SRC_SHA}${DIRTY}"
echo "REAL_REF_MEASURE CLIP=624x480 second-clip validation (not 320x240)"
echo "REAL_REF_MEASURE clip_stats: I4=167 I16=1003 wrap_events=6 qp[1,35] mb=1170 (vs 320: I4=79 I16=221 wrap=1)"
echo "REAL_REF_MEASURE pre-register HEADLINE: intra=0/1170 inter=0/12870 (chroma stub floors Y+U+V mb_exact)"
echo "REAL_REF_MEASURE pre-register LUMA: intra_y_mb=1100..1170/1170 intra_y_px=270000..299520/299520 (generalize 6dc5993; HIT_ABOVE if 1170)"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_REAL" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -GUSE_REAL_REF_COMMIT=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"

{
  echo "SOURCE_SHA=${SRC_SHA}${DIRTY}"
  "$BUILD_REAL/Vstream_path_full_frame_tb" \
    --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
    --native-candidate-i420-out "$REAL_CAND" \
    --inter-metadata-out "$REAL_META" --sequence "$SEQUENCE" \
    --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
    --json-out "$REAL_COMPARE" --trace-json-out "$REAL_REF_DIR/mb0_pipeline_trace.json" \
    --real-ref --expect-red
} | tee "$REAL_REF_DIR/sim.log"

python3 "$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQUENCE" \
  --golden-manifest "$GOLDEN_MANIFEST" \
  --golden-planes "$GOLDEN_PLANES" \
  --candidate-planes "$REAL_CAND" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --expect-red \
  --output "$REAL_SCORE"; echo "headline_score_true_rc=$?"

python3 - "$REAL_SCORE" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
sm=s.get("summary",s)
intra=sm.get("intra",{}); inter=sm.get("inter",{})
print(f"HEADLINE intra={intra.get('mb_exact',0)}/{intra.get('mb_total',0)} inter={inter.get('mb_exact',0)}/{inter.get('mb_total',0)}")
PY

REAL_LUMA="$REAL_REF_DIR/native_inter_luma_progress.json"
"$ROOT/tools/score_i420_luma_progress.py" \
  --candidate-planes "$REAL_CAND" \
  --golden-planes "$GOLDEN_PLANES" \
  --width "$WIDTH" --height "$HEIGHT" \
  --frames 12 \
  --output "$REAL_LUMA"; echo "luma_score_true_rc=$?"

python3 - "$REAL_LUMA" <<'PY'
import json,sys
sp=json.load(open(sys.argv[1]))
sm=sp.get("summary", sp)
i=sm.get("intra", {}); p=sm.get("inter", sm.get("predicted", {}))
print(f"LUMA intra_y_mb={i.get('y_mb_exact',0)}/{i.get('y_mb_total',0)} y_px={i.get('y_pixel_exact',i.get('y_px_exact',0))}/{i.get('y_pixel_total',i.get('y_px_total',0))} y_blk4={i.get('y_blk4_exact','?')}/{i.get('y_blk4_total','?')}")
print(f"LUMA inter_y_mb={p.get('y_mb_exact',0)}/{p.get('y_mb_total',0)}")
ymb=int(i.get('y_mb_exact',0))
print(f"LUMA_vs_PREREGISTER pre=1100..1170 actual={ymb} {'HIT' if 1100<=ymb<=1170 else 'MISS'}")
PY

python3 "$ROOT/tools/analyze_i_mb_luma_fail_breakdown.py" \
  --candidate "$REAL_CAND" \
  --reference "$GOLDEN_PLANES" \
  --goldens-dir "$ROOT/build/p3_full_frame/goldens_all_mbs" \
  --width "$WIDTH" --height "$HEIGHT" \
  --source-sha "${SRC_SHA}${DIRTY}" \
  -o "$REAL_REF_DIR/luma_fail_breakdown.json" \
  2>&1 | tee "$REAL_REF_DIR/luma_fail_breakdown.log"

echo "DONE measure"
