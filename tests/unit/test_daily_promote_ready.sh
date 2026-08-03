#!/usr/bin/env bash
# Host-only: c5382bee is LAB-OK but daily-promote READY=NO (fleet 2026-08-01).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass(){ echo "PASS $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# shellcheck source=/dev/null
source "$ROOT/scripts/rbf_ship_policy.sh"

set +e
out=$(rbf_policy_daily_promote_ready c5382bee73cecdee8220b811e529c297 2>&1); rc=$?
set -e
echo "c5382 daily_ready true rc=$rc"
echo "$out"
[[ "$rc" -eq 11 ]] && pass refuse-rc11 || fail refuse-rc11 "rc=$rc"
echo "$out" | grep -q 'DAILY_PROMOTE_READY=NO' && pass ready-no || fail ready-no missing
echo "$out" | grep -qi 'vertical_240\|even-only\|50%' && pass vert-blocker || fail vert-blocker missing
echo "$out" | grep -qi 'STALE\|frames_done' && pass stale-blocker || fail stale-blocker missing

# banned still refused by ship policy
set +e
rbf_policy_check_md5 8832824e000000000000000000000000 >/dev/null; brc=$?
set -e
echo "banned true rc=$brc"
[[ "$brc" -ne 0 ]] && pass banned-still || fail banned-still "rc=$brc"

# c5382bee still allowed for lab ship (not banned)
set +e
rbf_policy_check_md5 c5382bee73cecdee8220b811e529c297 >/dev/null; grc=$?
set -e
echo "lab-ship c5382 true rc=$grc"
[[ "$grc" -eq 0 ]] && pass lab-ok || fail lab-ok "rc=$grc"

# promote stage refuses without override
set +e
out=$(PROMOTE_EXECUTE=0 "$ROOT/scripts/promote_ddr_daily.sh" stage 2>&1); prc=$?
set -e
echo "promote stage true rc=$prc"
echo "$out" | tail -15
[[ "$prc" -eq 11 ]] && pass stage-refuse || fail stage-refuse "rc=$prc"
echo "$out" | grep -q REFUSE_DAILY_PROMOTE && pass stage-msg || fail stage-msg missing

# override opens path past ready-blocker. rc=127 (missing gate) is NOT success
# (parent 2026-08-02: absence was accepted as pass). Prefer positive gate token
# or a real later refuse (stamp/policy) — never bare command-not-found.
set +e
out=$(PROMOTE_ALLOW_KNOWN_DEFECTS=1 PROMOTE_EXECUTE=0 "$ROOT/scripts/promote_ddr_daily.sh" stage 2>&1); orc=$?
set -e
echo "promote stage override true rc=$orc"
echo "$out" | tail -15
[[ "$orc" -ne 11 ]] && pass override-not-11 || fail override-not-11 "rc=$orc"
# Discriminators: gate must be present (not GATE_MISSING / not naked 127-as-OK).
if echo "$out" | grep -q 'GATE_MISSING'; then
  fail override-gate-missing "promotion_gate_check absent (rc=$orc)"
elif echo "$out" | grep -q 'No such file or directory' \
  && echo "$out" | grep -q 'promotion_gate_check'; then
  fail override-cmd-not-found "rc=$orc still command-not-found"
elif [[ "$orc" -eq 127 ]]; then
  fail override-rc127 "rc=127 is not override success"
else
  pass override-not-gate-missing
fi
# Positive: either policy-local OK token, or an explicit REFUSE after the gate ran.
if echo "$out" | grep -q 'PROMOTE_POLICY_LOCAL_OK'; then
  pass override-gate-token
elif echo "$out" | grep -qE 'REFUSE stage:|daemon_stamp_check|PROMOTE_ALLOW_KNOWN_DEFECTS'; then
  pass override-reached-post-ready
else
  fail override-no-gate-evidence "no PROMOTE_POLICY_LOCAL_OK / REFUSE after override"
fi
echo "$out" | grep -q 'PROMOTE_ALLOW_KNOWN_DEFECTS' && pass override-warn || fail override-warn missing

# pair accepts 7c991e47 prefix with c5382bee
# shellcheck source=/dev/null
source "$ROOT/scripts/pair_ship_policy.sh"
set +e
pout=$(pair_policy_check c5382bee73cecdee8220b811e529c297 7c991e47 2>&1); prc=$?
set -e
echo "pair 7c991e47 true rc=$prc"
echo "$pout"
[[ "$prc" -eq 0 ]] && pass pair-7c99 || fail pair-7c99 "rc=$prc"

echo "=== summary pass=$PASS fail=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
