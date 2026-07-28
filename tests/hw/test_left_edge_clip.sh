#!/usr/bin/env bash
# HW gate: grade left-edge clip artifact on the HDMI output.
#
# After a core reset (idle logo state), the FPGA should display the grey Plex
# logo background from display column 0.  Known defect (RBF 00eebd5e): 24-pixel
# black strip on left edge — confirmed by source-vs-display comparison:
#   DDR source col 0 = luma 44 (grey)
#   HDMI display col 0-23 = luma 0 (BLACK)
#   HDMI display col 24 = luma 45 (content resumes — matches DDR)
#
# Usage:
#   tests/hw/test_left_edge_clip.sh [FRAME.jpg ...]
#
# Env:
#   HDMI_DEV           capture device (auto-detected if unset)
#   LEFT_EDGE_THRESHOLD max allowed black-px prefix before FAIL  [default: 4]
#   LEFT_EDGE_LOGO_ROW  display row in the logo band to sample   [default: 250]
#   LEFT_EDGE_EXPECT    PASS|FAIL  (FAIL = red-check mode)       [default: PASS]
#
# Exit: 0=PASS  1=FAIL  77=SKIP/UNSCORED
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tests/hw/hw_gate_common.sh"

THRESHOLD="${LEFT_EDGE_THRESHOLD:-4}"
LOGO_ROW="${LEFT_EDGE_LOGO_ROW:-250}"
EXPECT="${LEFT_EDGE_EXPECT:-PASS}"

args=("--threshold" "$THRESHOLD" "--logo-row" "$LOGO_ROW" "--expect" "$EXPECT")

if [[ $# -gt 0 ]]; then
  # Explicit frame files passed — analyse them directly (no device needed)
  python3 "$ROOT/scripts/grade_left_edge.py" "$@" "${args[@]}"
  rc=$?
else
  # Live capture: acquire lock before touching /dev/video0
  capture_lock_acquire
  python3 "$ROOT/scripts/grade_left_edge.py" "${args[@]}"
  rc=$?
fi

exit $rc
