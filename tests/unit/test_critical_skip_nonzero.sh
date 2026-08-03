#!/usr/bin/env bash
# CRITICAL soft-skip must not leave the suite at rc=0.
#
# OBSERVED DEFECT (parent 2026-08-02): make unit printed
#   GATE_SKIP CRITICAL live-pms-baseline-profile: reason=missing MISTERPLEX_BASELINE_KEY
# and still exited true rc=0. A CRITICAL gate that did not run is not success.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAP="$ROOT/scripts/run_with_skip_summary.py"
fails=0
applied=0
pass() { echo "PASS $*"; applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

[ -f "$WRAP" ] || { echo "FAIL missing $WRAP"; exit 1; }

# self-test includes escalate + preserve-fail
set +e
st_out=$(python3 "$WRAP" --self-test 2>&1)
st_rc=$?
set -e
echo "self_test true rc=$st_rc"
if [ "$st_rc" -eq 0 ] && printf '%s\n' "$st_out" | grep -q 'SELFTEST_CRITICAL_ESCALATE_OK'; then
  pass "run_with_skip_summary --self-test CRITICAL escalate"
else
  fail "self-test must cover CRITICAL escalate; rc=$st_rc"
  printf '%s\n' "$st_out" | tail -n 30
fi

# Direct: make-unit label + true + no credentials → rc=78 + unique token
WORK="$ROOT/build/test-critical-skip"
rm -rf "$WORK"
mkdir -p "$WORK"
set +e
out=$(
  env -u PLEX_BASE -u PLEX_TOKEN -u MISTERPLEX_BASELINE_KEY -u PLEX_KEY \
    -u MISTERPLEX_CONF -u MISTER_CONF HOME="$WORK" \
    python3 "$WRAP" --label make-unit -- true 2>&1
)
rc=$?
set -e
echo "critical_skip_true true rc=$rc"
printf '%s\n' "$out" | grep -E 'GATE_SKIP CRITICAL|GATE_SKIP_CRITICAL_NONZERO' || true
tok=$(printf '%s\n' "$out" | grep -c 'GATE_SKIP_CRITICAL_NONZERO' || true)
if [ "$rc" -eq 78 ] && [ "$tok" -ge 1 ]; then
  pass "CRITICAL inventory skip escalates true→rc=78 token lines=$tok"
else
  fail "want rc=78 + GATE_SKIP_CRITICAL_NONZERO; rc=$rc tok=$tok"
fi

# Preserve real failure (false → not 0, not forced solely if already failing)
set +e
out2=$(
  env -u PLEX_BASE -u PLEX_TOKEN -u MISTERPLEX_BASELINE_KEY -u PLEX_KEY \
    -u MISTERPLEX_CONF -u MISTER_CONF HOME="$WORK" \
    python3 "$WRAP" --label make-unit -- false 2>&1
)
rc2=$?
set -e
echo "critical_skip_false true rc=$rc2"
if [ "$rc2" -ne 0 ] && [ "$rc2" -ne 78 ]; then
  pass "wrapped failure rc=$rc2 preserved (not overwritten by 78)"
elif [ "$rc2" -eq 78 ]; then
  # false is 1 on bash; python false may differ — accept non-zero only
  fail "wrapped false became 78 (should keep command rc)"
else
  fail "wrapped false must be nonzero; rc=$rc2"
fi

# Structural: source contains escalate
if grep -q 'GATE_SKIP_CRITICAL_NONZERO' "$WRAP" \
  && grep -q 'severity == "CRITICAL"' "$WRAP"; then
  pass "wrapper source escalates CRITICAL severity"
else
  fail "wrapper missing CRITICAL escalate logic"
fi

# conf resolves BASELINE_KEY (parity with PLEX_BASE)
if grep -q 'conf_val("MISTERPLEX_BASELINE_KEY"' "$WRAP" \
  || grep -q "conf_val('MISTERPLEX_BASELINE_KEY'" "$WRAP"; then
  pass "MISTERPLEX_BASELINE_KEY resolvable from conf"
else
  fail "BASELINE_KEY must resolve from conf like PLEX_BASE"
fi

echo "applied_match_count=$applied fails=$fails"
if [ "$fails" -ne 0 ]; then
  echo "test_critical_skip_nonzero: FAILED"
  exit 1
fi
echo "test_critical_skip_nonzero: OK"
exit 0
