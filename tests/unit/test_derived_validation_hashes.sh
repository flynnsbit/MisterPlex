#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ASSET="build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264"
MANIFEST="tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json"
OUT="build/derived_validation"
mkdir -p "$OUT"

if [[ ! -f "$ASSET" ]]; then
  echo "SKIP-NOT-PASS derived_validation_hashes: missing $ASSET; regenerate via docs/derived-validation-assets.md" >&2
  exit 77
fi

python3 tools/derived_h264_plane_hashes.py verify --manifest "$MANIFEST" --input "$ASSET"

python3 - <<'PY'
import json
from pathlib import Path
manifest = Path("tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json")
out = Path("build/derived_validation/derived_hashes_bad_y_manifest.json")
data = json.loads(manifest.read_text())
frames = data["frames"]
uv_diff = sum(1 for f in frames if f["planes"]["U"] != f["planes"]["V"])
unique_y = len({f["planes"]["Y"] for f in frames})
if uv_diff < 1700:
    raise SystemExit(f"FAIL derived hash fixture: U/V swap coverage too weak uv_diff={uv_diff}")
if unique_y < 1700:
    raise SystemExit(f"FAIL derived hash fixture: luma variation too weak unique_y={unique_y}")
# Mutate a frame/plane hash that the content actually varies, not a low-chroma grey sentinel.
idx = next(i for i, f in enumerate(frames) if f["planes"]["U"] != f["planes"]["V"] and i > 0)
frames[idx]["planes"]["Y"] = "0" * 64
frames[idx]["frame_sha256"] = "0" * 64
out.write_text(json.dumps(data, indent=2) + "\n")
print(f"DERIVED_HASH_MUTATION frame={idx} uv_diff={uv_diff} unique_y={unique_y}")
PY

set +e
python3 tools/derived_h264_plane_hashes.py verify --manifest "$OUT/derived_hashes_bad_y_manifest.json" --input "$ASSET" > "$OUT/bad_y_verify.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  cat "$OUT/bad_y_verify.log"
  echo "FAIL derived hash red-check: mutated Y hash unexpectedly verified" >&2
  exit 1
fi
grep -q 'plane_hash .* plane=Y' "$OUT/bad_y_verify.log"
echo "OK derived_validation_hashes: derived real-content per-plane hashes verify and mutated Y hash goes red"
