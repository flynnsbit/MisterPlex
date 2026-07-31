#!/usr/bin/env bash
# Unit gate for tools/measure_overlay_edge.py (w-osd-hires parent criterion).
#
# Must:
#   1) selftest: native 1080p chevron PASS, bilinear-upscaled 640→1080 FAIL
#   2) if a parent-archived HDMI capture is present, FAIL it (criterion shown RED)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/measure_overlay_edge.py"
FIX="$ROOT/build/osd-hires-fixtures"
mkdir -p "$FIX"

echo "test_overlay_edge_measure: selftest"
set +e
OUT="$(python3 "$TOOL" --selftest --selftest-dir "$FIX" 2>&1)"
RC=$?
set -e
echo "$OUT"
echo "true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL: measure_overlay_edge --selftest expected rc=0"
  exit 1
fi
echo "$OUT" | grep -q 'SELFTEST PASS' || {
  echo "FAIL: missing SELFTEST PASS line"
  exit 1
}

# Optional archive (copied into worktree by the worker; not required in CI).
ARCHIVE=""
for cand in \
  "$ROOT/.agent-work/osd-hires/overlay_lowres_evidence.png" \
  "/home/flynnsbit/.copilot/session-state/1b1fb4ae-c05c-44bc-883d-5af91466e181/files/overlay_lowres_evidence.png" \
  "$ROOT/.agent-work/osd-hires/idle_warm.png" \
  "$ROOT/../rollback-honest/build/pair-visual/idle_warm.png" \
  "/home/flynnsbit/Projects/MisterPlex/.worktrees/rollback-honest/build/pair-visual/idle_warm.png"
do
  if [[ -f "$cand" ]]; then
    ARCHIVE="$cand"
    break
  fi
done

if [[ -n "$ARCHIVE" ]]; then
  echo "test_overlay_edge_measure: archive RED proof on $ARCHIVE"
  set +e
  AOUT="$(python3 "$TOOL" "$ARCHIVE" 2>&1)"
  ARC=$?
  set -e
  echo "$AOUT"
  echo "true rc=$ARC"
  if [[ "$ARC" -eq 0 ]]; then
    echo "FAIL: archived idle_warm.png unexpectedly PASSED edge criterion"
    exit 1
  fi
  if [[ "$ARC" -ne 1 ]]; then
    echo "FAIL: archive score expected rc=1 (criterion fail), got $ARC"
    exit 1
  fi
  echo "$AOUT" | grep -q 'VERDICT=FAIL' || {
    echo "FAIL: archive missing VERDICT=FAIL"
    exit 1
  }
else
  echo "test_overlay_edge_measure: no archive PNG found — selftest only (OK)"
fi

echo "test_overlay_edge_measure: PASS"
exit 0
