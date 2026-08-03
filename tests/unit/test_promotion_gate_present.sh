#!/usr/bin/env bash
# Host-only: promotion_gate_check must EXIST and be reachable from promote path.
#
# OBSERVED DEFECT (parent 2026-08-02): scripts/promotion_gate_check.sh was absent
# on main while promote_ddr_daily.sh still called it. bash rc=127 (command not
# found) was treated as "opened the override path" by tests that only checked
# rc!=11 — PINNOTFOUND family (gate that cannot run must be RED).
#
# Prefer POSITIVE artifacts the gate uniquely produces (PROMOTE_POLICY_LOCAL_OK /
# GATE_MISSING), not "the command refused" (several gates can refuse).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/scripts/promotion_gate_check.sh"
PROMOTE="$ROOT/scripts/promote_ddr_daily.sh"
PROBE="$ROOT/scripts/pair_live_probe.inc.sh"
WORK="$ROOT/build/test-promotion-gate-present"
rm -rf "$WORK"
mkdir -p "$WORK"
fails=0
applied=0
pass() { echo "PASS $*"; applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

# --- 1) positive: gate files present + executable ---------------------------
if [ -x "$GATE" ]; then
  pass "promotion_gate_check.sh exists and is executable"
else
  fail "GATE_MISSING $GATE (must ship; absence is hard fail not skip)"
fi
if [ -f "$PROBE" ]; then
  pass "pair_live_probe.inc.sh present (gate dependency)"
else
  fail "missing pair_live_probe.inc.sh"
fi
bash -n "$GATE" && pass "promotion_gate_check.sh bash -n" || fail "bash -n gate"

# --- 2) positive: policy-local emits PROMOTE_POLICY_LOCAL_OK ----------------
printf 'fake-rbf-body\n' >"$WORK/fake.rbf"
printf 'fake-daemon-body\n' >"$WORK/fake.daemon"
chmod +x "$WORK/fake.daemon"
RBF_MD5=$(md5sum "$WORK/fake.rbf" | awk '{print $1}')
DAE_MD5=$(md5sum "$WORK/fake.daemon" | awk '{print $1}')
set +e
pl_out=$(
  PROMOTE_EXPECT_CORE_MD5="$RBF_MD5" \
  PROMOTE_EXPECT_DAEMON_MD5="$DAE_MD5" \
  PROMOTE_PAIR_CHECK=0 \
  "$GATE" policy-local "$WORK/fake.rbf" "$WORK/fake.daemon" 2>&1
)
pl_rc=$?
set -e
echo "policy_local true rc=$pl_rc"
# Unique positive token from THIS gate (not a generic refuse).
pl_ok_lines=$(printf '%s\n' "$pl_out" | grep -c 'PROMOTE_POLICY_LOCAL_OK' || true)
echo "policy_local PROMOTE_POLICY_LOCAL_OK lines=$pl_ok_lines"
if [ "$pl_rc" -eq 0 ] && [ "$pl_ok_lines" -ge 1 ]; then
  pass "policy-local positive token PROMOTE_POLICY_LOCAL_OK (lines=$pl_ok_lines)"
else
  fail "policy-local must emit PROMOTE_POLICY_LOCAL_OK rc=0; rc=$pl_rc lines=$pl_ok_lines"
  printf '%s\n' "$pl_out" | tail -n 20
fi

# --- 3) promote_ddr_daily wires run_promotion_gate_check (source proof) ------
if grep -q 'run_promotion_gate_check' "$PROMOTE" \
  && grep -q 'require_promotion_gate_check' "$PROMOTE" \
  && grep -q 'GATE_MISSING' "$PROMOTE"; then
  pass "promote_ddr_daily requires gate via run_promotion_gate_check + GATE_MISSING"
else
  fail "promote_ddr_daily must require_promotion_gate_check / GATE_MISSING"
fi

# --- 4) positive wiring: stage override reaches policy-local OK token -------
# Use synthetic pins so we do not depend on release artifact daemon md5 pins.
set +e
st_out=$(
  PROMOTE_ALLOW_KNOWN_DEFECTS=1 \
  PROMOTE_EXECUTE=0 \
  PROMOTE_EXPECT_CORE_MD5="$RBF_MD5" \
  PROMOTE_EXPECT_DAEMON_MD5="$DAE_MD5" \
  PROMOTE_RBF="$WORK/fake.rbf" \
  PROMOTE_DAEMON="$WORK/fake.daemon" \
  PROMOTE_PAIR_CHECK=0 \
  "$PROMOTE" stage "$WORK/fake.rbf" "$WORK/fake.daemon" 2>&1
)
st_rc=$?
set -e
echo "promote_stage true rc=$st_rc"
st_ok=$(printf '%s\n' "$st_out" | grep -c 'PROMOTE_POLICY_LOCAL_OK' || true)
echo "promote_stage PROMOTE_POLICY_LOCAL_OK lines=$st_ok"
# stage may later refuse stamp (rc!=0) — that is fine; the vf/gate lesson is
# that OUR gate's positive token must appear (discriminating coverage).
if [ "$st_ok" -ge 1 ]; then
  pass "promote stage path emits gate token PROMOTE_POLICY_LOCAL_OK (lines=$st_ok)"
else
  fail "promote stage must reach promotion_gate_check (want PROMOTE_POLICY_LOCAL_OK); rc=$st_rc"
  printf '%s\n' "$st_out" | tail -n 30
fi
# Must NOT be bare command-not-found without GATE_MISSING when gate present.
if printf '%s\n' "$st_out" | grep -q 'No such file or directory' \
  && ! printf '%s\n' "$st_out" | grep -q 'PROMOTE_POLICY_LOCAL_OK'; then
  fail "promote still hits missing-script path"
else
  pass "promote does not miss gate script when present"
fi

# --- 5) RBG mutation: hide the gate → GATE_MISSING + nonzero (not silent) ---
# Rename gate aside; promote must print GATE_MISSING and nonzero rc.
hide="$WORK/promotion_gate_check.sh.hidden"
mv "$GATE" "$hide"
set +e
mut_out=$(
  PROMOTE_ALLOW_KNOWN_DEFECTS=1 \
  PROMOTE_EXECUTE=0 \
  PROMOTE_EXPECT_CORE_MD5="$RBF_MD5" \
  PROMOTE_EXPECT_DAEMON_MD5="$DAE_MD5" \
  "$PROMOTE" stage "$WORK/fake.rbf" "$WORK/fake.daemon" 2>&1
)
mut_rc=$?
set -e
# restore immediately
mv "$hide" "$GATE"
chmod +x "$GATE"
echo "mutation_missing_gate true rc=$mut_rc"
echo "$mut_out" | tail -n 15
gm=$(printf '%s\n' "$mut_out" | grep -c 'GATE_MISSING' || true)
echo "GATE_MISSING lines=$gm"
if [ "$mut_rc" -ne 0 ] && [ "$gm" -ge 1 ]; then
  pass "mutation: missing gate → GATE_MISSING + nonzero rc=$mut_rc (applied-match)"
else
  fail "mutation must GATE_MISSING + nonzero; rc=$mut_rc gm=$gm"
fi
# 127 is fail, never "override success"
if [ "$mut_rc" -eq 11 ]; then
  fail "mutation returned ready-blocker 11 instead of GATE_MISSING"
fi

# --- 6) daily-promote-ready must not treat 127 as override success ----------
# Source structural: override path must require gate present / reject 127.
if grep -q 'override-not-11' "$ROOT/tests/unit/test_daily_promote_ready.sh"; then
  # After fix, test should mention GATE_MISSING or PROMOTE_POLICY or not-127
  if grep -qE 'GATE_MISSING|PROMOTE_POLICY_LOCAL|127' "$ROOT/tests/unit/test_daily_promote_ready.sh"; then
    pass "test_daily_promote_ready no longer treats bare rc!=11 as success"
  else
    fail "test_daily_promote_ready still only checks rc!=11 (127 was green)"
  fi
else
  pass "test_daily_promote_ready override assertion rewritten"
fi

echo "applied_match_count=$applied fails=$fails"
if [ "$fails" -ne 0 ]; then
  echo "test_promotion_gate_present: FAILED"
  exit 1
fi
echo "test_promotion_gate_present: OK"
exit 0
