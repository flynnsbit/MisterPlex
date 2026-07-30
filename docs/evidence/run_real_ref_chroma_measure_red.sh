#!/usr/bin/env bash
# REAL_REF + chroma/headline measure (rtl/chroma-intra lane).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
BITSTREAM="${FULL_FRAME_BITSTREAM:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264}"
TOP="$ROOT/tests/rtl/stream_path_full_frame_tb_top.sv"
TB="$ROOT/tests/rtl/stream_path_full_frame_tb.cpp"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
PRODUCT_RTL=(
  stream_path.sv stream_ingest.sv ddr_bitstream_reader.sv bitstream_fifo.sv
  nalu_scanner.sv sps_parser.sv pps_parser.sv slice_hdr_parser.sv
  h264_iq_idct_4x4.sv h264_dequant4x4_serial.sv h264_inter_pred.sv h264_deblock.sv h264_dpb.sv
  decode_stub.sv h264_p_mb_traverse.sv h264_byte_ram_sp.sv
  h264_i16_dc_hadamard.sv h264_i16_dc_hadamard_serial.sv
  h264_i_res_recon_sink.sv h264_intra_pred.sv h264_recon_frame_store.sv
  h264_cavlc_residual.sv
  h264_chroma_qp.sv h264_chroma_dc_hadamard_inv.sv
  h264_p_chroma_res_apply.sv
)
RTL_ARGS=()
for f in "${PRODUCT_RTL[@]}"; do RTL_ARGS+=("$RTL_DIR/$f"); done

SOURCE_SHA=$(sha256sum "$BITSTREAM" | awk '{print $1}')
WIDTH=320; HEIGHT=240
SEQUENCE="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json"
GOLDEN_PLANES="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv"
GOLDEN_MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json"

BUILD_REAL="$ROOT/build/verilator/stream_path_full_frame_real_ref_chroma_red"
REAL_REF_DIR="$ROOT/build/p3_full_frame_real_ref_chroma_red"
mkdir -p "$BUILD_REAL" "$REAL_REF_DIR"
REAL_META="$REAL_REF_DIR/native_inter_metadata.json"
REAL_CAND="$REAL_REF_DIR/native_inter_candidate.i420"
REAL_SCORE="$REAL_REF_DIR/native_inter_candidate_score.json"
REAL_COMPARE="$REAL_REF_DIR/frame_planes_compare.json"

SRC_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIRTY=""; git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet || DIRTY="-dirty"
echo "REAL_REF_CHROMA source_sha=${SRC_SHA}${DIRTY}"
echo "PRE-REGISTER STORE: unique=300/300 (I+P bitmap)"
echo "PRE-REGISTER HEADLINE: intra=300/300 (hold) inter_full=1850..1939/3300 (P-chroma residual; ceiling=luma-exact 1939)"
echo "PRE-REGISTER mech: P res_blk chroma export + apply; store waits p_chr_mb_done when cbp[5:4]!=0"
echo "PRE-REGISTER clip: 320x240_12f (reject 624 constant_y degeneracy)"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_REAL" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -GUSE_REAL_REF_COMMIT=1 -Wno-fatal \
  -DDECODE_STUB_FAULT_SKIP_INTER_CHROMA_RESIDUAL \
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
sm=sp.get("summary",sp)
i=sm.get("intra",sp.get("intra",{}))
p=sm.get("inter",sm.get("predicted",sp.get("inter",{})))
print(f"LUMA intra_y_mb={i.get('y_mb_exact','?')}/{i.get('y_mb_total','?')} y_px={i.get('y_px_exact','?')}/{i.get('y_px_total','?')}")
print(f"LUMA inter_y_mb={p.get('y_mb_exact',0)}/{p.get('y_mb_total',0)}")
PY
# Frame-0 UV gradient (scorer is Y∧U∧V; this is separate)
python3 - "$REAL_CAND" "$GOLDEN_PLANES" <<'PY'
from pathlib import Path
import sys
W,H=320,240
cand=Path(sys.argv[1]).read_bytes(); gold=Path(sys.argv[2]).read_bytes()
ys,us=W*H,(W//2)*(H//2)
def pl(b,o,n): return memoryview(b)[o:o+n]
cy,cu,cv=pl(cand,0,ys),pl(cand,ys,us),pl(cand,ys+us,us)
gy,gu,gv=pl(gold,0,ys),pl(gold,ys,us),pl(gold,ys+us,us)
def mb_y(a,b,x,y):
    for dy in range(16):
        r=(y*16+dy)*W+x*16
        if bytes(a[r:r+16])!=bytes(b[r:r+16]): return False
    return True
def mb_c(a,b,x,y):
    for dy in range(8):
        r=(y*8+dy)*(W//2)+x*8
        if bytes(a[r:r+8])!=bytes(b[r:r+8]): return False
    return True
y=u=v=uv=yuv=0
for my in range(H//16):
  for mx in range(W//16):
    ye,ue,ve=mb_y(cy,gy,mx,my),mb_c(cu,gu,mx,my),mb_c(cv,gv,mx,my)
    y+=ye;u+=ue;v+=ve;uv+=(ue and ve);yuv+=(ye and ue and ve)
print(f"F0_GRAD y_mb={y}/300 u_mb={u}/300 v_mb={v}/300 uv_mb={uv}/300 yuv_mb={yuv}/300")
PY
# STORE gate from sim.log
rg -n "I_RECON_DONE|STORE_MB_BITMAP unique=" "$REAL_REF_DIR/sim.log" | head -20 || true

python3 "$ROOT/tools/analyze_i_mb_luma_fail_breakdown.py" \
  --candidate "$REAL_CAND" \
  --reference "$GOLDEN_PLANES" \
  --goldens-dir "$ROOT/build/p3_full_frame/goldens_all_mbs" \
  --width "$WIDTH" --height "$HEIGHT" \
  --source-sha "${SRC_SHA}${DIRTY}" \
  -o "$REAL_REF_DIR/luma_fail_breakdown.json" \
  2>&1 | tee "$REAL_REF_DIR/luma_fail_breakdown.log"

echo "DONE measure"
