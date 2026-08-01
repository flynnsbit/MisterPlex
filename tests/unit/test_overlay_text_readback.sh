#!/usr/bin/env bash
# String read-back acceptance for playback overlay.
# Gate specification = real HDMI pair (same device + grabber):
#   RED  tests/unit/fixtures/overlay_readback/overlay_lowres_evidence.png
#   GREEN tests/unit/fixtures/overlay_readback/overlay_FIXED_db3d9367_stopped.png
# Synthetic green alone is NOT sufficient (parent rule: red-before-green is half).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TOOL=tools/readback_overlay_text.py

echo "== selftest-font-measure (reported font must match paint) =="
python3 "$TOOL" --selftest-font-measure
rc_font=$?
echo "selftest-font-measure captured rc=$rc_font"

echo "== selftest-pair (RED mush + GREEN silicon FIXED) =="
python3 "$TOOL" --selftest-pair
rc_pair=$?
echo "selftest-pair captured rc=$rc_pair"

echo "== direct FIXED image (must PASS) =="
python3 "$TOOL" --image tests/unit/fixtures/overlay_readback/overlay_FIXED_db3d9367_stopped.png --expect STOPPED
rc_fix=$?
echo "fixed captured rc=$rc_fix"

echo "== direct OLD evidence (must FAIL measured) =="
set +e
python3 "$TOOL" --image tests/unit/fixtures/overlay_readback/overlay_lowres_evidence.png --expect STOPPED
rc_old=$?
set -e
echo "old captured rc=$rc_old"

if [[ "$rc_font" -ne 0 ]]; then
  echo "FAIL: selftest-font-measure"
  echo "true rc=1"
  exit 1
fi
if [[ "$rc_pair" -ne 0 ]]; then
  echo "FAIL: selftest-pair"
  echo "true rc=1"
  exit 1
fi
if [[ "$rc_fix" -ne 0 ]]; then
  echo "FAIL: FIXED image not GREEN"
  echo "true rc=1"
  exit 1
fi
if [[ "$rc_old" -ne 1 ]]; then
  echo "FAIL: OLD evidence must be measured FAIL rc=1 (got $rc_old)"
  echo "true rc=1"
  exit 1
fi
# GREEN fixture font must be measured 12x16 (product bank), not template guess.
fixed_meta=$(python3 "$TOOL" --image tests/unit/fixtures/overlay_readback/overlay_FIXED_db3d9367_stopped.png --expect STOPPED | sed -n 's/^meta=//p')
echo "fixed_meta_line=$fixed_meta"
if ! echo "$fixed_meta" | grep -q "'font': '12x16'"; then
  echo "FAIL: FIXED STOPPED must measure font=12x16 (got $fixed_meta)"
  echo "true rc=1"
  exit 1
fi
echo "test_overlay_text_readback: OK"
echo "true rc=0"
exit 0
