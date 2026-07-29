#!/usr/bin/env bash
# Full-frame product path (stream_path.h264_decode_core.dec_px_*) vs FFmpeg yuv420p.
# Default: settled 624x480 Baseline IDR+P (first 2 VCL NALs), deblock disabled golden,
# then score the same product dump against a deblock-enabled FFmpeg golden.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
export OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; product full-frame compare was NOT run." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi
command -v ffmpeg >/dev/null || { echo "RTL SIM ERROR: ffmpeg not found" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "RTL SIM ERROR: ffprobe not found" >&2; exit 2; }

BITSTREAM="${PRODUCT_FRAME_BITSTREAM:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264}"
SEQUENCE="${PRODUCT_FRAME_SEQUENCE:-$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_624x480_sequence_v1.json}"
GOLDEN_OFF="${PRODUCT_FRAME_GOLDEN_OFF:-$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_i420.yuv}"
GOLDEN_OFF_MANIFEST="${PRODUCT_FRAME_GOLDEN_OFF_MANIFEST:-$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_frame_planes_v1.json}"
MAX_VCL="${PRODUCT_FRAME_MAX_VCL:-2}"
BUILD="$ROOT/build/verilator/stream_path_product_frame"
OUT_DIR="$ROOT/build/p3_product_frame"
TOP="$ROOT/tests/rtl/stream_path_full_frame_tb_top.sv"
TB="$ROOT/tests/rtl/stream_path_full_frame_tb.cpp"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"

PRODUCT_RTL=(
  stream_path.sv stream_ingest.sv ddr_bitstream_reader.sv ddr_bitstream_prefetch.sv
  bitstream_fifo.sv nalu_scanner.sv h264_rbsp_window.sv h264_i_mb_feed.sv
  sps_parser.sv pps_parser.sv h264_cavlc_residual.sv slice_hdr_parser.sv
  h264_iq_idct_4x4.sv h264_inter_pred.sv h264_pskip_mv.sv h264_inter_part.sv
  h264_intra_pred.sv h264_intra_nb_ctx.sv h264_deblock.sv h264_dpb.sv
  h264_decode_top.sv h264_decode_core.sv decode_stub.sv
)

for f in "$BITSTREAM" "$SEQUENCE" "$GOLDEN_OFF" "$GOLDEN_OFF_MANIFEST" "$TOP" "$TB" "$QIP"; do
  [[ -f "$f" ]] || { echo "RTL SIM ERROR: missing $f" >&2; exit 2; }
done

RTL_ARGS=()
for rtl in "${PRODUCT_RTL[@]}"; do
  [[ -f "$RTL_DIR/$rtl" ]] || { echo "RTL SIM ERROR: missing $RTL_DIR/$rtl" >&2; exit 2; }
  grep -q "rtl/$rtl" "$QIP" || { echo "RTL SIM ERROR: files.qip missing rtl/$rtl" >&2; exit 2; }
  RTL_ARGS+=("$RTL_DIR/$rtl")
done

read -r WIDTH HEIGHT FRAMES < <(
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,nb_read_frames \
    -count_frames -of csv=p=0 "$BITSTREAM" | tr ',' ' '
)
SOURCE_SHA=$(sha256sum "$BITSTREAM" | awk '{print $1}')
if ! grep -q "$SOURCE_SHA" "$SEQUENCE"; then
  echo "RTL SIM ERROR: sequence sha256 does not match bitstream" >&2
  exit 2
fi

mkdir -p "$BUILD" "$OUT_DIR"
GOLDEN_ON="$OUT_DIR/ffmpeg_deblock_enabled_i420.yuv"
GOLDEN_ON_MANIFEST="$OUT_DIR/ffmpeg_deblock_enabled_manifest.json"

echo "RTL SIM: product full-frame compare ${WIDTH}x${HEIGHT} max_vcl=${MAX_VCL} sha=${SOURCE_SHA:0:12}" >&2
echo "RTL SIM: using $VERILATOR_VERSION" >&2

# Provenance-check undeblocked golden, then mint an enabled-deblock FFmpeg reference.
"$ROOT/tools/extract_h264_frame_planes.py" --verify \
  --input "$BITSTREAM" --sequence "$SEQUENCE" \
  --planes "$GOLDEN_OFF" --manifest "$GOLDEN_OFF_MANIFEST" \
  --expected-h264-loop-filter disabled

"$ROOT/tools/extract_h264_frame_planes.py" \
  --input "$BITSTREAM" --sequence "$SEQUENCE" \
  --planes-out "$GOLDEN_ON" --manifest-out "$GOLDEN_ON_MANIFEST" \
  --h264-loop-filter enabled
"$ROOT/tools/extract_h264_frame_planes.py" --verify \
  --input "$BITSTREAM" --sequence "$SEQUENCE" \
  --planes "$GOLDEN_ON" --manifest "$GOLDEN_ON_MANIFEST" \
  --expected-h264-loop-filter enabled

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"

PRODUCT_I420="$OUT_DIR/product_candidate.i420"
PRODUCT_JSON_OFF="$OUT_DIR/product_compare_deblock_off.json"
PRODUCT_JSON_ON="$OUT_DIR/product_compare_deblock_on.json"
SIM_LOG="$OUT_DIR/sim_deblock_off.log"

set +e
"$BUILD/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" \
  --golden-planes "$GOLDEN_OFF" \
  --golden-manifest "$GOLDEN_OFF_MANIFEST" \
  --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" \
  --width "$WIDTH" --height "$HEIGHT" \
  --max-vcl-frames "$MAX_VCL" \
  --skip-rgb-compare \
  --h264-loop-filter disabled \
  --product-candidate-i420-out "$PRODUCT_I420" \
  --product-json-out "$PRODUCT_JSON_OFF" \
  >"$SIM_LOG" 2>&1
SIM_RC=$?
set -e
cat "$SIM_LOG"

echo "---- score product dump vs deblock-DISABLED FFmpeg golden ----" >&2
set +e
OFF_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQUENCE" \
  --golden-manifest "$GOLDEN_OFF_MANIFEST" \
  --golden-planes "$GOLDEN_OFF" \
  --candidate-planes "$PRODUCT_I420" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --max-frames "$MAX_VCL" \
  --output "$OUT_DIR/score_deblock_off.json" 2>&1)"
OFF_RC=$?
set -e
printf '%s\n' "$OFF_OUT"

echo "---- score product dump vs deblock-ENABLED FFmpeg golden ----" >&2
set +e
ON_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQUENCE" \
  --golden-manifest "$GOLDEN_ON_MANIFEST" \
  --golden-planes "$GOLDEN_ON" \
  --candidate-planes "$PRODUCT_I420" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter enabled \
  --candidate-h264-loop-filter disabled \
  --allow-loop-filter-mismatch \
  --max-frames "$MAX_VCL" \
  --output "$OUT_DIR/score_deblock_on.json" 2>&1)"
ON_RC=$?
set -e
printf '%s\n' "$ON_OUT"

python3 - "$PRODUCT_JSON_OFF" "$OUT_DIR/score_deblock_off.json" "$OUT_DIR/score_deblock_on.json" "$SIM_RC" "$OFF_RC" "$ON_RC" "$OUT_DIR/summary.txt" <<'PY'
import json, sys
from pathlib import Path

prod_path, off_path, on_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sim_rc, off_rc, on_rc = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
summary_path = Path(sys.argv[7])

def load(p):
    if not p.exists():
        return None
    return json.loads(p.read_text())

prod = load(prod_path)
off = load(off_path)
on = load(on_path)

def fmt_frame(score, idx, label):
    if not score:
        return f"{label}: no-score"
    frames = score.get("frames") or []
    if idx >= len(frames):
        return f"{label}: frame{idx}=missing"
    fr = frames[idx]
    kind = fr.get("slice_kind", "?")
    mb_e = fr.get("mb_exact")
    mb_t = fr.get("mb_total")
    fb = None
    for pl in fr.get("planes", []):
        if pl.get("first_bad"):
            fb = pl["first_bad"]
            fb["plane"] = pl.get("plane")
            break
    # prefer summary first_bad if frame-level lacks mb
    summ_fb = (score.get("summary") or {}).get("first_bad")
    if summ_fb and summ_fb.get("frame_index") == idx:
        fb = summ_fb
    if mb_e == mb_t and mb_t:
        return f"{label}: exact-match mb={mb_e}/{mb_t} kind={kind}"
    if fb:
        mb_x = fb.get("mb_x")
        mb_y = fb.get("mb_y")
        mb_addr = fb.get("mb_addr")
        if mb_addr is None and mb_x is not None and mb_y is not None:
            # coded 624 -> 39 mb wide; fall back from geometry if present
            w = (score.get("geometry") or {}).get("width", 624)
            mb_w = (int(w) + 15) // 16
            mb_addr = int(mb_y) * mb_w + int(mb_x)
        # mismatch count
        mism = 0
        for pl in fr.get("planes", []):
            mism += int(pl.get("total_pixels", 0)) - int(pl.get("exact_pixels", 0))
        return (
            f"{label}: FAIL first_mb=addr={mb_addr} (x={mb_x},y={mb_y}) "
            f"plane={fb.get('plane')} mism_px={mism} mb_exact={mb_e}/{mb_t} kind={kind}"
        )
    return f"{label}: FAIL mb_exact={mb_e}/{mb_t} kind={kind}"

lines = []
obs = (prod or {}).get("observability", {})
lines.append(
    f"sim_rc={sim_rc} product_frames_done={obs.get('product_frames_done')} "
    f"px_writes={obs.get('product_px_writes')} max_mb={obs.get('product_max_mb_addr')} "
    f"rbsp_ovf={obs.get('product_rbsp_overflow')} desync={obs.get('product_slice_desync')} "
    f"desync_mb={obs.get('product_desync_mb')} desync_cause={obs.get('product_desync_cause')}"
)
lines.append(fmt_frame(off, 0, "IDR_deblock_OFF"))
lines.append(fmt_frame(on, 0, "IDR_deblock_ON"))
lines.append(fmt_frame(off, 1, "P_deblock_OFF"))
lines.append(fmt_frame(on, 1, "P_deblock_ON"))
text = "\n".join(lines) + "\n"
summary_path.write_text(text)
print(text)
# Exit non-zero only if sim hard-failed before producing a dump.
sys.exit(0 if Path(off_path).exists() or sim_rc == 0 else 1)
PY

echo "OK product-frame harness finished; see $OUT_DIR/summary.txt" >&2
