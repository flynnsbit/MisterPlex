#!/usr/bin/env bash
# Guards the release ship-safety gate added after a hardware-reproduced defect:
# `make package` used to happily build a tarball whose (core, daemon) pair the
# project's own ship policy REFUSES. Installed on the device, that tarball
# rendered a black screen (v0.3.0 core never frees a DDR bank for the DDR-era
# daemon: "PLXD bank-select swap_pending", free_mask=0, frames_done frozen;
# 90/90 captured frames mean luma 0.00, parent, viewed pixels, 2026-08-02).
#
# These assertions are about behavior a naive/regressed implementation fails:
#   1. pair policy REFUSES the exact pair that black-screened  (negative case)
#   2. pair policy ACCEPTS a matrix pair                        (positive case)
#   3. package_release.sh actually consults the policy
#   4. the gate blocks the tarball, i.e. it runs BEFORE `tar`
#   5. there is no env-var bypass that would let the bad pair ship anyway
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POLICY="$ROOT/scripts/pair_ship_policy.sh"
PKG="$ROOT/scripts/package_release.sh"
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

for f in "$POLICY" "$PKG"; do
  [ -r "$f" ] || { echo "FAIL missing $f"; exit 1; }
done

# 1) negative case: the pair that black-screened the device must be refused.
out="$("$POLICY" check 41adb98c 88e292fd 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q PAIR_REFUSE; then
  pass "policy refuses the hardware-reproduced black-screen pair 41adb98c/88e292fd (rc=$rc)"
else
  fail "policy did NOT refuse 41adb98c/88e292fd (rc=$rc): $out"
fi

# 2) positive case: a real matrix pair must still be accepted, so the gate is
#    not trivially satisfied by refusing everything.
out="$("$POLICY" check c5382bee 3883f5ab 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q PAIR_OK; then
  pass "policy accepts matrix pair c5382bee/3883f5ab (rc=0)"
else
  fail "policy rejected a known matrix pair c5382bee/3883f5ab (rc=$rc): $out"
fi

# 3) the packager must actually consult the policy.
if grep -q 'pair_ship_policy.sh" check' "$PKG"; then
  pass "package_release.sh consults pair_ship_policy.sh"
else
  fail "package_release.sh no longer consults pair_ship_policy.sh"
fi

# 4) the gate must run BEFORE the tarball is created, or a refused pair still
#    lands on disk as a shippable artifact.
gate_line=$(grep -n 'pair_ship_policy.sh" check' "$PKG" | head -1 | cut -d: -f1)
tar_line=$(grep -n '^tar -C' "$PKG" | head -1 | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$tar_line" ] && [ "$gate_line" -lt "$tar_line" ]; then
  pass "pair gate (line $gate_line) runs before tar (line $tar_line)"
else
  fail "pair gate must precede tar (gate=${gate_line:-none} tar=${tar_line:-none})"
fi

# 5) no environment bypass. A gate you can switch off from the environment is
#    not a gate; the supported path is hardware-validating a new matrix row.
if awk "NR>=${gate_line:-0} && NR<=${gate_line:-0}+34" "$PKG" \
     | grep -qE '\$\{(PAIR_[A-Z_]*(SKIP|FORCE|BYPASS|ALLOW)|SKIP_PAIR|FORCE_PAIR|ALLOW_BAD_PAIR)[A-Z_]*:?-'; then
  fail "package_release.sh pair gate exposes an environment bypass"
else
  pass "pair gate has no environment bypass"
fi

if [ "$fails" -eq 0 ]; then
  echo "test_release_pair_gate: OK"
  exit 0
fi
echo "test_release_pair_gate: FAILED ($fails)"
exit 1
