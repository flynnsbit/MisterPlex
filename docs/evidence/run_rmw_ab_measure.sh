#!/usr/bin/env bash
# Focused REAL_REF measure for RMW A+B (no full unit suite).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
BITSTREAM="${1:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264}"
TAG="${2:-clip1}"
FAULT_G="${3:-}"  # e.g. -GFAULT_SERIAL_IQ_ZERO=1
OUT_DIR="$ROOT/docs/evidence/_local_logs/rmw_ab_${TAG}"
BUILD="$ROOT/build/verilator/rmw_ab_${TAG}${FAULT_G:+_fault}"
mkdir -p "$OUT_DIR" "$BUILD"

TOP="$ROOT/tests/rtl/stream_path_full_frame_tb_top.sv"
TB="$ROOT/tests/rtl/stream_path_full_frame_tb.cpp"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
PRODUCT_RTL=(
  stream_path.sv stream_ingest.sv ddr_bitstream_reader.sv bitstream_fifo.sv
  nalu_scanner.sv sps_parser.sv pps_parser.sv slice_hdr_parser.sv
  h264_iq_idct_4x4.sv h264_inter_pred.sv h264_deblock.sv h264_dpb.sv
  decode_stub.sv h264_p_mb_traverse.sv h264_byte_ram_sp.sv
  h264_i16_dc_hadamard.sv h264_i16_dc_hadamard_serial.sv h264_dequant4x4_serial.sv
  h264_i_res_recon_sink.sv h264_intra_pred.sv h264_recon_frame_store.sv
  h264_cavlc_residual.sv
)
RTL_ARGS=()
for rtl in "${PRODUCT_RTL[@]}"; do RTL_ARGS+=("$RTL_DIR/$rtl"); done

read -r WIDTH HEIGHT FRAMES < <(
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,nb_read_frames \
    -count_frames -of csv=p=0 "$BITSTREAM" | tr ',' ' '
)
SOURCE_SHA=$(sha256sum "$BITSTREAM" | awk '{print $1}')
SRC_SHA="$(git -C "$ROOT" rev-parse HEAD)"
# Sequence/golden — reuse full-frame test discovery via existing dirs if present
REF_DIR="$ROOT/build/p3_full_frame"
# Ensure golden exists by invoking the compare script's early parts if missing
if [[ ! -f "$REF_DIR/golden_planes.i420" ]]; then
  echo "Building goldens via full-frame harness prelude..."
  # Minimal: run extract path from test by calling it with a timeout? Instead:
  FULL_FRAME_BITSTREAM="$BITSTREAM" "$ROOT/tests/unit/test_stream_path_full_frame_compare.sh" >/dev/null 2>"$OUT_DIR/prelude.log" || true
fi
# Locate sequence + golden from standard paths
SEQUENCE="${FULL_FRAME_SEQUENCE:-}"
if [[ -z "$SEQUENCE" ]]; then
  for s in \
    "$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_${WIDTH}x${HEIGHT}_12f.sequence.json" \
    "$ROOT/tests/fixtures/p3_inter_pred/sequences/${WIDTH}x${HEIGHT}_12f.json" \
    "$REF_DIR/sequence.json"
  do
    [[ -f "$s" ]] && SEQUENCE="$s" && break
  done
fi
GOLDEN_PLANES="${GOLDEN_PLANES:-$REF_DIR/golden_planes.i420}"
GOLDEN_MANIFEST="${GOLDEN_MANIFEST:-$REF_DIR/golden_manifest.json}"
if [[ ! -f "$GOLDEN_PLANES" || ! -f "$GOLDEN_MANIFEST" ]]; then
  echo "ERROR missing golden $GOLDEN_PLANES / $GOLDEN_MANIFEST — run full compare once" >&2
  exit 2
fi
if [[ -z "$SEQUENCE" || ! -f "$SEQUENCE" ]]; then
  # try find
  SEQUENCE=$(find "$ROOT/tests/fixtures" -name "*${WIDTH}x${HEIGHT}*" -name '*.json' | head -1 || true)
fi
echo "MEASURE tag=$TAG src=$SRC_SHA ${WIDTH}x${HEIGHT} frames=$FRAMES fault='$FAULT_G'" | tee "$OUT_DIR/header.txt"
echo "BITSTREAM=$BITSTREAM SEQUENCE=$SEQUENCE" | tee -a "$OUT_DIR/header.txt"

GARGS=(-GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -GUSE_REAL_REF_COMMIT=1)
if [[ -n "$FAULT_G" ]]; then
  # FAULT_G like FAULT_SERIAL_IQ_ZERO=1
  GARGS+=("-G${FAULT_G}")
fi

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module stream_path_full_frame_tb \
  "${GARGS[@]}" -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB" 2>"$OUT_DIR/build.log"

echo "SOURCE_SHA=$SRC_SHA" > "$OUT_DIR/sim.log"
set +e
"$BUILD/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
  --native-candidate-i420-out "$OUT_DIR/candidate.i420" \
  --inter-metadata-out "$OUT_DIR/meta.json" --sequence "${SEQUENCE:-/dev/null}" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$OUT_DIR/compare.json" \
  --real-ref --expect-red \
  >>"$OUT_DIR/sim.log" 2>&1
SIM_RC=$?
set -e
echo "true rc=$SIM_RC" | tee -a "$OUT_DIR/sim.log"

rg -n 'STAGE_CYCLES|I_RECON_DONE|STORE_MB_BITMAP|LUMA|intra_y|REAL_REF' "$OUT_DIR/sim.log" | head -40 | tee "$OUT_DIR/summary_grep.txt" || true

if [[ -f "$OUT_DIR/candidate.i420" && -n "${SEQUENCE:-}" && -f "${SEQUENCE:-}" ]]; then
  set +e
  "$ROOT/tools/score_i420_luma_progress.py" \
    --sequence "$SEQUENCE" \
    --golden-manifest "$GOLDEN_MANIFEST" \
    --golden-planes "$GOLDEN_PLANES" \
    --candidate-planes "$OUT_DIR/candidate.i420" \
    --candidate-colorspace I420_NATIVE \
    --reference-h264-loop-filter disabled \
    --candidate-h264-loop-filter disabled \
    --mb-metadata "$OUT_DIR/meta.json" \
    --output "$OUT_DIR/luma_progress.json" 2>"$OUT_DIR/luma_score.err"
  echo "luma_score true rc=$?" | tee -a "$OUT_DIR/sim.log"
  set -e
  python3 - "$OUT_DIR/luma_progress.json" <<'PY' 2>/dev/null | tee -a "$OUT_DIR/sim.log" || true
import json,sys
d=json.load(open(sys.argv[1]))
# tolerate schema variants
sp=d.get("summary") or d.get("luma") or d
print("LUMA_JSON", json.dumps(sp)[:500])
PY
fi
echo "DONE $OUT_DIR"
exit 0
