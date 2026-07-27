#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/i420_candidate_score"
mkdir -p "$OUT"

SEQ="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json"
MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json"
GOLDEN="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv"
SCORE_JSON="$OUT/score.json"
FAULT="$OUT/plex_inter_p16_320x240_12f_fault.i420"
FAULT_JSON="$OUT/score_fault.json"
MB_META="$OUT/inter_mb_metadata.json"

python3 - "$MB_META" <<'PY'
import json
import sys
from pathlib import Path

data = {
    "format": "misterplex.p3.inter_mb_metadata.v1",
    "geometry": {"width": 320, "height": 240},
    "frames": [
        {
            "frame_index": 1,
            "slice_kind": "P",
            "macroblocks": [
                {
                    "mb_index": 0,
                    "mb_x": 0,
                    "mb_y": 0,
                    "mb_type": "P_Skip",
                    "ref_idx_l0": 0,
                    "mv_l0": [0, 0],
                    "pred_y": [0] * 256,
                }
            ],
        }
    ],
}
Path(sys.argv[1]).write_text(json.dumps(data, indent=2) + "\n")
PY

"$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" \
  --golden-manifest "$MANIFEST" \
  --golden-planes "$GOLDEN" \
  --candidate-planes "$GOLDEN" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --mb-metadata "$MB_META" \
  --output "$SCORE_JSON"

python3 - "$SCORE_JSON" <<'PY'
import json
import sys

score = json.load(open(sys.argv[1]))
if score["summary"]["intra"]["mb_exact"] != 300 or score["summary"]["intra"]["mb_total"] != 300:
    raise SystemExit("FAIL candidate score: intra baseline is not 300/300")
if score["summary"]["inter"]["mb_exact"] != 3300 or score["summary"]["inter"]["mb_total"] != 3300:
    raise SystemExit("FAIL candidate score: inter golden self-compare is not 3300/3300")
by_type = score["summary"]["inter_by_mb_type"]
if by_type["P_Skip"] != {"mb_exact": 1, "mb_total": 1}:
    raise SystemExit(f"FAIL candidate score: P_Skip breakdown wrong: {by_type['P_Skip']}")
if by_type["P_UNKNOWN"] != {"mb_exact": 3299, "mb_total": 3299}:
    raise SystemExit(f"FAIL candidate score: P_UNKNOWN breakdown wrong: {by_type['P_UNKNOWN']}")
if score["summary"]["first_bad"] is not None or not score["summary"]["strict_pass"]:
    raise SystemExit("FAIL candidate score: golden self-compare was not exact")
PY

python3 - "$GOLDEN" "$FAULT" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_bytes()
buf = bytearray(src)
frame_bytes = 320 * 240 * 3 // 2
buf[frame_bytes] ^= 1  # first Y byte of first P frame
Path(sys.argv[2]).write_bytes(buf)
PY

set +e
FAULT_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" \
  --golden-manifest "$MANIFEST" \
  --golden-planes "$GOLDEN" \
  --candidate-planes "$FAULT" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --mb-metadata "$MB_META" \
  --output "$FAULT_JSON" \
  --expect-red 2>&1)"
FAULT_RC=$?
set -e
if [[ "$FAULT_RC" -ne 0 ]]; then
  printf '%s\n' "$FAULT_OUT"
  echo "FAIL candidate score red-check: faulted P frame did not produce expected-red success" >&2
  exit 1
fi
grep -q 'inter=3299/3300 strict_pass=0' <<<"$FAULT_OUT"
python3 - "$FAULT_JSON" <<'PY'
import json
import sys

score = json.load(open(sys.argv[1]))
fb = score["summary"]["first_bad_inter"]
if fb["frame_index"] != 1 or fb["mb_index"] != 0 or fb["plane"] != "Y":
    raise SystemExit(f"FAIL candidate score red-check: wrong first_bad_inter {fb}")
if fb.get("mb_type") != "P_Skip" or fb.get("ref_idx_l0") != 0 or fb.get("mv_l0") != {"x": 0, "y": 0}:
    raise SystemExit(f"FAIL candidate score red-check: missing MB type/MV context {fb}")
if len(fb.get("candidate_block", [])) != 256 or len(fb.get("reference_block", [])) != 256:
    raise SystemExit("FAIL candidate score red-check: missing first-bad sample blocks")
if len(fb.get("predicted_block", [])) != 256:
    raise SystemExit("FAIL candidate score red-check: missing predicted sample block from metadata")
PY

set +e
COLOR_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" --golden-manifest "$MANIFEST" --golden-planes "$GOLDEN" \
  --candidate-planes "$GOLDEN" --candidate-colorspace I420_FROM_RGB565 \
  --reference-h264-loop-filter disabled --candidate-h264-loop-filter disabled 2>&1)"
COLOR_RC=$?
set -e
if [[ "$COLOR_RC" -ne 9 ]]; then
  printf '%s\n' "$COLOR_OUT"
  echo "FAIL candidate score colorspace refusal: rc=$COLOR_RC want 9" >&2
  exit 1
fi
grep -q 'candidate colorspace' <<<"$COLOR_OUT"

set +e
LOOP_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQ" --golden-manifest "$MANIFEST" --golden-planes "$GOLDEN" \
  --candidate-planes "$GOLDEN" --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled --candidate-h264-loop-filter enabled 2>&1)"
LOOP_RC=$?
set -e
if [[ "$LOOP_RC" -ne 9 ]]; then
  printf '%s\n' "$LOOP_OUT"
  echo "FAIL candidate score loop-filter refusal: rc=$LOOP_RC want 9" >&2
  exit 1
fi
grep -q 'loop-filter mismatch' <<<"$LOOP_OUT"

echo "test_i420_candidate_score: OK separated intra/inter score and colorspace/loop-filter/fault RED checks"
