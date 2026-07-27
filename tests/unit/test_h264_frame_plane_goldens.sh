#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

command -v ffmpeg >/dev/null || { echo "FRAME PLANE ERROR: ffmpeg reference decoder not found" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "FRAME PLANE ERROR: ffprobe not found" >&2; exit 2; }

TOOL="$ROOT/tools/extract_h264_frame_planes.py"
OUT="$ROOT/build/p3_frame_planes"
mkdir -p "$OUT"

check_fixture() {
  local name="$1"
  local bitstream="$2"
  local sequence="$3"
  local planes="$4"
  local manifest="$5"
  local expect_w="${6:-0}"
  local expect_h="${7:-0}"
  local gen_planes="$OUT/${name}.i420"
  local gen_manifest="$OUT/${name}.json"

  args=(
    --input "$bitstream"
    --sequence "$sequence"
    --planes-out "$gen_planes"
    --manifest-out "$gen_manifest"
  )
  if [[ "$expect_w" != "0" ]]; then args+=(--expect-width "$expect_w"); fi
  if [[ "$expect_h" != "0" ]]; then args+=(--expect-height "$expect_h"); fi
  "$TOOL" "${args[@]}"
  cmp -s "$gen_planes" "$planes"
  "$TOOL" --verify --input "$bitstream" --sequence "$sequence" --planes "$planes" --manifest "$manifest"
  "$TOOL" --verify --input "$bitstream" --sequence "$sequence" --planes "$planes" --manifest "$manifest" \
    --candidate-planes "$gen_planes"
}

check_fixture \
  wcap_residual14_idr_plus_p \
  tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p.264 \
  tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p_sequence_v1.json \
  tests/fixtures/p3_frame_planes/wcap_residual14_idr_plus_p_i420.yuv \
  tests/fixtures/p3_frame_planes/wcap_residual14_idr_plus_p_frame_planes_v1.json

check_fixture \
  plex_inter_p16_320x240_12f \
  tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264 \
  tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json \
  tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv \
  tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json

check_fixture \
  plex_inter_p16_624x480_12f \
  tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264 \
  tests/fixtures/p3_multinal/plex_inter_p16_624x480_sequence_v1.json \
  tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_i420.yuv \
  tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_frame_planes_v1.json \
  624 480

python3 - <<'PY'
from pathlib import Path
src = Path("tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv")
dst = Path("build/p3_frame_planes/plex_inter_p16_320x240_12f_corrupt.i420")
data = bytearray(src.read_bytes())
data[76800] ^= 0x55  # first U byte of frame 0
dst.write_bytes(data)
PY

set +e
"$TOOL" --verify \
  --input tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264 \
  --sequence tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json \
  --planes tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv \
  --manifest tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json \
  --candidate-planes build/p3_frame_planes/plex_inter_p16_320x240_12f_corrupt.i420 \
  > "$OUT/corrupt_compare.log" 2>&1
RED_RC=$?
set -e
if [[ "$RED_RC" -eq 0 ]]; then
  cat "$OUT/corrupt_compare.log"
  echo "FAIL frame-plane red-check: corrupt U plane unexpectedly matched" >&2
  exit 1
fi
grep -q 'FRAME_PLANE_COMPARE raw frame=0 plane=U' "$OUT/corrupt_compare.log"
grep -q 'candidate plane comparison diverged from golden' "$OUT/corrupt_compare.log"
"$TOOL" --verify \
  --input tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264 \
  --sequence tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json \
  --planes tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv \
  --manifest tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json \
  --candidate-planes build/p3_frame_planes/plex_inter_p16_320x240_12f_corrupt.i420 \
  --expect-red

echo "test_h264_frame_plane_goldens: OK regenerated I420 goldens, provenance verified, corrupt-plane RED checked"
