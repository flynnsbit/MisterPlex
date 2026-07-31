#!/usr/bin/env bash
# String read-back acceptance for playback overlay (parent correction).
# Lattice pitch is NOT the gate. Exact string recovery is.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
TOOL=tools/readback_overlay_text.py
EVIDENCE=.agent-work/osd-hires/overlay_lowres_evidence.png

echo "== selftest-red (evidence must NOT recover STOPPED) =="
python3 "$TOOL" --selftest-red --expect STOPPED
rc_red=$?
echo "selftest-red captured rc=$rc_red"

echo "== selftest-green (scale>=2 even-y after DE cull) =="
python3 "$TOOL" --selftest-green --expect STOPPED
rc_green=$?
echo "selftest-green captured rc=$rc_green"

if [[ ! -f "$EVIDENCE" ]]; then
  echo "WARN missing $EVIDENCE"
fi

if [[ "$rc_red" -ne 0 ]]; then
  echo "FAIL: evidence selftest-red"
  echo "true rc=1"
  exit 1
fi
if [[ "$rc_green" -ne 0 ]]; then
  echo "FAIL: synthetic selftest-green"
  echo "true rc=1"
  exit 1
fi
echo "test_overlay_text_readback: OK"
echo "true rc=0"
exit 0
