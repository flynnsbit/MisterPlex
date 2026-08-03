#!/usr/bin/env bash
# Content 1280 beam tier (parent FACT 2): glass already 720p; core must be able
# to emit 1280 DE when FRAME_W=1280 + PRESENT_BEAM_960 (default OFF).
# Negative: hard 960-only elab / H_TOTAL=1182 with 1280 DE must not return.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
fail() { echo "FAIL test_content_1280_beam_tier: $*"; exit 1; }

[[ -f "$CORE" && -f "$QSF" && -f "$BEAM" ]] || fail "missing sources"

# Must NOT require exact 960×540 only
if grep -q 'PRESENT_BEAM_960 requires FRAME_W=960 FRAME_H=540' "$CORE"; then
  fail "BEAM still hard-requires 960x540 (blocks content 1280)"
fi
grep -q 'max content tier 1280x720' "$CORE" || fail "missing 1280x720 max tier elab"

# Wide line class
grep -q 'BEAM_HTOT_WIDE   = 1312' "$CORE" || grep -q 'BEAM_HTOT_WIDE = 1312' "$CORE" || \
  fail "missing H_TOTAL=1312 wide tier"
grep -q 'BEAM_WIDE_TIER' "$CORE" || fail "missing BEAM_WIDE_TIER"
grep -q 'RT_MAX_HDE' "$CORE" || fail "missing RT_MAX_HDE from FRAME"

# Active product still 640 (default-off)
grep -q 'VERILOG_MACRO "FRAME_W=640"' "$QSF" || fail "product FRAME_W not 640"
grep -q 'VERILOG_MACRO "FRAME_H=480"' "$QSF" || fail "product FRAME_H not 480"
# Recipe commented, not active
grep -q '#set_global_assignment -name VERILOG_MACRO "FRAME_W=1280"' "$QSF" || \
  fail "missing commented FRAME_1280 recipe"
grep -q '#set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"' "$QSF" || \
  fail "missing commented BEAM recipe"
if grep -qE '^set_global_assignment -name VERILOG_MACRO "FRAME_W=1280"' "$QSF"; then
  fail "FRAME_1280 must not be active without fit grant"
fi
if grep -qE '^set_global_assignment -name VERILOG_MACRO "PRESENT_BEAM_960=1"' "$QSF"; then
  fail "PRESENT_BEAM_960 must not be active without fit grant"
fi

# Beam module can pad H_TOTAL for large DE (negative naive: fixed 1182 only)
grep -q 'htot_min_pad' "$BEAM" || fail "beam missing htot pad"

# Arithmetic oracle: 20 MHz 1312x736 cannot do 24 Hz
awk 'BEGIN{
  f=20e6/(1312*736)
  if (f >= 24.0) { print "FAIL oracle fps>=24"; exit 1 }
  if (f < 20.5 || f > 21.0) { print "FAIL oracle fps", f; exit 1 }
  print "OK oracle 1312x736@20MHz fps=" f " (cadence holds 24 content)"
}'

echo "PASS test_content_1280_beam_tier true rc=0"
exit 0
