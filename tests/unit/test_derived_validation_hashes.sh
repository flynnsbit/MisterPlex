#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ASSET_DIR="${ARM_PROFILE_ASSET_DIR:-artifacts/local/arm-profile-sample}"
ASSET="$ASSET_DIR/derived_realcontent_624x480_baseline_ref1_nob_1800f.264"
MANIFEST="tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json"
SLICE="tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv"
SLICE_MANIFEST="tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled_v1.json"
OUT="build/derived_validation"
mkdir -p "$OUT"

python3 tools/derived_h264_slice_fixture.py verify --slice "$SLICE" --manifest "$SLICE_MANIFEST"

if [[ -f "$ASSET" ]]; then
  python3 tools/derived_h264_plane_hashes.py verify --manifest "$MANIFEST" --input "$ASSET"
else
  echo "INFO derived_validation_hashes: optional full 1800-frame check skipped; ASSET_EXPIRED missing $ASSET"
fi

python3 - <<'PY'
import json
from pathlib import Path
manifest = Path("tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled_v1.json")
out = Path("build/derived_validation/derived_slice_bad_y_manifest.json")
data = json.loads(manifest.read_text())
frames = data["frames"]
uv_diff = sum(1 for f in frames if f["planes"]["U"] != f["planes"]["V"])
unique_y = len({f["planes"]["Y"] for f in frames})
if uv_diff != len(frames):
    raise SystemExit(f"FAIL derived hash fixture: U/V swap coverage too weak uv_diff={uv_diff}")
if unique_y < len(frames) - 1:
    raise SystemExit(f"FAIL derived hash fixture: luma variation too weak unique_y={unique_y}")
# Mutate a frame/plane hash that the content actually varies, not a low-chroma grey sentinel.
idx = next(i for i, f in enumerate(frames) if f["planes"]["U"] != f["planes"]["V"])
frames[idx]["planes"]["Y"] = "0" * 64
frames[idx]["frame_sha256"] = "0" * 64
out.write_text(json.dumps(data, indent=2) + "\n")
print(f"DERIVED_HASH_MUTATION frame={idx} uv_diff={uv_diff} unique_y={unique_y}")
PY

set +e
python3 tools/derived_h264_slice_fixture.py verify --slice "$SLICE" --manifest "$OUT/derived_slice_bad_y_manifest.json" > "$OUT/bad_y_verify.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  cat "$OUT/bad_y_verify.log"
  echo "FAIL derived hash red-check: mutated Y hash unexpectedly verified" >&2
  exit 1
fi
grep -q 'plane_hash .* plane=Y' "$OUT/bad_y_verify.log"

python3 - <<'PY'
from pathlib import Path
width, height = 624, 480
frame_size = width * height * 3 // 2
y_size = width * height
uv_size = (width // 2) * (height // 2)
src = Path("tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv")
dst = Path("build/derived_validation/derived_slice_uv_swapped.yuv")
data = src.read_bytes()
out = bytearray()
for off in range(0, len(data), frame_size):
    frame = data[off:off + frame_size]
    y = frame[:y_size]
    u = frame[y_size:y_size + uv_size]
    v = frame[y_size + uv_size:]
    out += y + v + u
dst.write_bytes(out)
PY

set +e
python3 tools/derived_h264_slice_fixture.py verify --slice "$OUT/derived_slice_uv_swapped.yuv" --manifest "$SLICE_MANIFEST" > "$OUT/uv_swap_verify.log" 2>&1
uv_rc=$?
set -e
if [[ "$uv_rc" -eq 0 ]]; then
  cat "$OUT/uv_swap_verify.log"
  echo "FAIL derived hash red-check: U/V swapped slice unexpectedly verified" >&2
  exit 1
fi
grep -q 'plane_hash .* plane=U' "$OUT/uv_swap_verify.log"
grep -q 'plane_hash .* plane=V' "$OUT/uv_swap_verify.log"

python3 - <<'PY'
from pathlib import Path
width, height = 624, 480
frame_size = width * height * 3 // 2
y_size = width * height
uv_size = (width // 2) * (height // 2)
src = Path("tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv")
data = bytearray(src.read_bytes())
u = y_size
v = y_size + uv_size
data[u] ^= 0x5a
Path("build/derived_validation/derived_slice_bad_u.yuv").write_bytes(data)
data = bytearray(src.read_bytes())
data[v] ^= 0xa5
Path("build/derived_validation/derived_slice_bad_v.yuv").write_bytes(data)
PY

set +e
python3 tools/derived_h264_slice_fixture.py verify --slice "$OUT/derived_slice_bad_u.yuv" --manifest "$SLICE_MANIFEST" > "$OUT/bad_u_verify.log" 2>&1
bad_u_rc=$?
set -e
if [[ "$bad_u_rc" -eq 0 ]]; then
  cat "$OUT/bad_u_verify.log"
  echo "FAIL derived hash red-check: corrupted U byte unexpectedly verified" >&2
  exit 1
fi
grep -q 'plane_hash .* plane=U' "$OUT/bad_u_verify.log"

set +e
python3 tools/derived_h264_slice_fixture.py verify --slice "$OUT/derived_slice_bad_v.yuv" --manifest "$SLICE_MANIFEST" > "$OUT/bad_v_verify.log" 2>&1
bad_v_rc=$?
set -e
if [[ "$bad_v_rc" -eq 0 ]]; then
  cat "$OUT/bad_v_verify.log"
  echo "FAIL derived hash red-check: corrupted V byte unexpectedly verified" >&2
  exit 1
fi
grep -q 'plane_hash .* plane=V' "$OUT/bad_v_verify.log"

test -x tools/derived_h264_slice_fixture.py
test -x tools/derived_h264_plane_hashes.py
echo "test_derived_validation_hashes: OK always-on 8-frame slice verifies; corrupted Y hash, U/V swap, and single-byte U/V corruptions go red"
