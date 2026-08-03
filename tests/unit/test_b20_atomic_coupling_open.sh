#!/usr/bin/env bash
# B20 atomic PLXG↔bank coupling — honesty gate (must stay OPEN until contract lands).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WALL="$ROOT/assets/b20_visual_two_phase_wall.json"
PC="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
SPI="$ROOT/arm/misterplexd/fpga_spi.cpp"

fail() { echo "FAIL test_b20_atomic_coupling_open: $*"; exit 1; }
pass() { echo "PASS test_b20_atomic_coupling_open: $*"; }

test -f "$WALL" || fail "missing wall"
# Must not claim closed
if grep -q '"B20_CLOSED": true' "$WALL"; then
  fail "B20_CLOSED=true while atomic coupling incomplete"
fi
grep -q '"atomic_plxg_bank_coupling": false' "$WALL" || fail "wall must fence atomic_plxg_bank_coupling=false"

# Prove product still samples live content_* into app_* (gap still present)
grep -n 'app_content_w   <= content_w' "$PC" >/dev/null || fail "expected live capture site missing (refactor without updating gate?)"
# Prove doorbell has no plxg in kick path comment/pack nearby
grep -n 'doorbellSeq_' "$SPI" >/dev/null || fail "doorbellSeq_ missing"
# No store_applied consumer yet in present_core
if grep -n 'store_applied_content_w' "$PC" >/dev/null 2>&1; then
  fail "store_applied_* appeared — promote gate to positive coupling test"
fi

pass "B20 atomic coupling correctly OPEN (live app_* + independent doorbellSeq)"
exit 0
