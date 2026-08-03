#!/usr/bin/env bash
# B20 atomic PLXG↔bank — honesty gate (OPEN until contract lands).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WALL="$ROOT/assets/b20_visual_two_phase_wall.json"
PC="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
SPI="$ROOT/arm/misterplexd/fpga_spi.cpp"

fail() { echo "FAIL test_b20_atomic_coupling_open: $*"; exit 1; }
pass() { echo "PASS test_b20_atomic_coupling_open: $*"; }

test -f "$WALL" || fail "missing wall"
if grep -q '"B20_CLOSED": true' "$WALL"; then
  fail "B20_CLOSED=true while atomic coupling incomplete"
fi
grep -q '"atomic_plxg_bank_coupling": false' "$WALL" || fail "wall must fence atomic_plxg_bank_coupling=false"
grep -q 'wmem_residual' "$WALL" || fail "wall must record wmem_residual"

# w-clock still samples live content_* into app_* (gap still present)
grep -n 'app_content_w   <= content_w' "$PC" >/dev/null || fail "expected live capture site missing"
# No store_applied consumer yet
if grep -n 'store_applied_content_w' "$PC" >/dev/null 2>&1; then
  fail "store_applied_* appeared — promote gate to positive coupling test"
fi
grep -n 'doorbellSeq_' "$SPI" >/dev/null || fail "doorbellSeq_ missing"

# Residual docs present
test -f "$ROOT/.agent-work/w-clock/B20_WMEM_RESIDUAL_rd_duck.md" || fail "missing w-mem residual doc"
grep -q 'applied_geom_seq_r <= rt_geom_seq' \
  "$ROOT/.agent-work/w-clock/B20_WMEM_RESIDUAL_rd_duck.md" || fail "residual must quote live seq assign"

pass "B20 atomic OPEN: live app_* + w-mem applied_seq residual fenced"
exit 0
