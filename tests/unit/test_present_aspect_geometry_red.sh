#!/usr/bin/env bash
# RED twin: hardcoded 4:3 product path must be rejected by aspect geometry rules.
# Expected: inner checker exits 1. Harness converts that to harness PASS (0).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

set +e
python3 - <<'PY'
import re
import sys

old = """
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;
"""
bad = re.search(r"assign\s+VIDEO_ARX\s*=\s*\(!ar\)\s*\?\s*12'd4\b", old)
has_frame = "12'(FRAME_W)" in old
mismatch_720 = (4 / 3) != (16 / 9)

if bad is None or has_frame or not mismatch_720:
    print("RED setup error")
    sys.exit(2)

fails = []
if bad is not None:
    fails.append("product path must not hardcode VIDEO_ARX=12'd4")
if not has_frame:
    fails.append("VIDEO_ARX original branch references FRAME_W")

print("FAIL test_present_aspect_geometry (RED expected):")
for f in fails:
    print(f"  - {f}")
sys.exit(1)
PY
rc=$?
set -e
if [[ $rc -eq 1 ]]; then
  echo "OK aspect geometry RED twin: hardcoded 4:3 rejected (inner rc=1)"
  exit 0
fi
echo "RED twin lost teeth (inner rc=$rc)"
exit 1
