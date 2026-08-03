#!/usr/bin/env bash
# PLXG reset baseline liveness — honesty gate (rd-duck).
# Retained-DDR baseline without commit is NOT full reset closure: passive baseline
# can swallow a fresh pre-poll publish. No boot nonce/ACK => OPEN.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WALL="$ROOT/assets/b20_visual_two_phase_wall.json"
FENCE="$ROOT/.agent-work/w-clock/PLXG_RESET_BASELINE_LIVENESS_FENCE.md"
# Poller may live only on w-mem / integration branches
POLLER_CANDIDATES=(
  "$ROOT/fpga/Plex_MiSTer/rtl/plxg_ddr_poller.sv"
  "$ROOT/../MisterPlex-wt-mem/fpga/Plex_MiSTer/rtl/plxg_ddr_poller.sv"
)

fail() { echo "FAIL test_plxg_reset_baseline_open: $*"; exit 1; }
pass() { echo "PASS test_plxg_reset_baseline_open: $*"; }

test -f "$WALL" || fail "missing wall"
test -f "$FENCE" || fail "missing fence doc"

# Wall must not claim closed
if grep -q '"plxg_reset_baseline_liveness_closed": true' "$WALL"; then
  fail "wall claims plxg_reset_baseline_liveness_closed=true without nonce/ACK proof"
fi
grep -q '"plxg_reset_baseline_liveness_closed": false' "$WALL" || \
  fail "wall must fence plxg_reset_baseline_liveness_closed=false"
grep -q 'boot_nonce_or_ack' "$WALL" || fail "wall must name required closure (boot_nonce_or_ack)"

# Fence must quote the source LIMITATION class
grep -q 'passive baseline cannot distinguish' "$FENCE" || \
  fail "fence must quote poller LIMITATION"
grep -qE 'not.*stale-live closure|liveness/ownership' "$FENCE" || \
  fail "fence must classify as liveness/ownership (not stale-live closure)"
grep -q 'B20_CLOSED' "$FENCE" || fail "fence must keep B20_CLOSED context"

# If poller is visible, require baseline-without-commit + LIMITATION header
POLLER=""
for p in "${POLLER_CANDIDATES[@]}"; do
  if [[ -f "$p" ]]; then POLLER=$p; break; fi
done
if [[ -n "$POLLER" ]]; then
  echo "MEASURE poller=$POLLER"
  grep -q 'S_BASELINE' "$POLLER" || fail "poller missing S_BASELINE"
  grep -q 'boot_baseline_done' "$POLLER" || fail "poller missing boot_baseline_done"
  # Product: first coherent without baseline goes to S_BASELINE not immediate PUSH-only
  grep -q 'st   <= S_BASELINE' "$POLLER" || grep -q 'st <= S_BASELINE' "$POLLER" || \
    fail "poller missing baseline transition"
  grep -q 'passive baseline cannot distinguish' "$POLLER" || \
    fail "poller header must admit pre-poll fresh-write race"
  # Must not claim closed in poller header
  if grep -qi 'reset liveness closed' "$POLLER"; then
    fail "poller claims reset liveness closed"
  fi
  # RED twin still present for retained promote
  grep -q 'FAULT_PLXG_NO_BASELINE' "$POLLER" || fail "missing FAULT_PLXG_NO_BASELINE red twin"
  echo "OK poller admits baseline + LIMITATION ($POLLER)"
else
  echo "OK poller not on this tree — fence+wall only (w-mem owns RTL)"
fi

# B20 wall still open
grep -q '"B20_CLOSED": false' "$WALL" || fail "B20_CLOSED must remain false"

pass "PLXG reset baseline liveness OPEN (no boot nonce/ACK); not stale-live closure"
exit 0
