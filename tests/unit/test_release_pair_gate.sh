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
MAKEFILE="$ROOT/Makefile"
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
gate_line=$(grep -n 'pair_ship_policy.sh" check' "$PKG" | tail -1 | cut -d: -f1)
tar_line=$(grep -n '^tar -C' "$PKG" | head -1 | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$tar_line" ] && [ "$gate_line" -lt "$tar_line" ]; then
  pass "pair gate (line $gate_line) runs before tar (line $tar_line)"
else
  fail "pair gate must precede tar (gate=${gate_line:-none} tar=${tar_line:-none})"
fi

# 5) no environment bypass. A gate you can switch off from the environment is
#    not a gate; the supported path is hardware-validating a new matrix row.
#    Scanned over the WHOLE file on purpose: this previously scanned a 34-line
#    window from the first pair check, so adding an earlier check would silently
#    move the window off the real gate and stop testing it.
if grep -qE '\$\{(PAIR_[A-Z_]*(SKIP|FORCE|BYPASS|ALLOW)|SKIP_PAIR|FORCE_PAIR|ALLOW_BAD_PAIR)[A-Z_]*:?-' "$PKG"; then
  fail "package_release.sh exposes an environment bypass for the pair gate"
else
  pass "pair gate has no environment bypass"
fi

# 6) POSITIVE CAPABILITY. A packager that can only ever refuse is not a shipping
#    path ("refusal is not delivery"): before DAEMON_PATH existed this script
#    rebuilt the daemon every run, so its md5 could never match a validated row
#    while the core stayed pinned, and `make package` refused unconditionally.
#    Default ship = stamped ba2ec313 daemon 509b0c75 (not regressing e9f79de2).
if "$ROOT/scripts/pair_ship_policy.sh" check \
     c5382bee73cecdee8220b811e529c297 509b0c7592e0e9e38686f9eb8e2cb047 >/dev/null 2>&1; then
  pass "stamped lab pair c5382bee/509b0c75 is authorised (shipping path exists)"
else
  fail "no stamped pair is authorised; package_release can only refuse"
fi

# 7) that path must be reachable from the packager: it has to be able to ship a
#    pre-validated daemon rather than one it just built.
if grep -qE '\$\{DAEMON_PATH:-|\$\{DAEMON_PATH\}' "$PKG"; then
  pass "package_release.sh can ship a pre-validated daemon (DAEMON_PATH)"
else
  fail "package_release.sh cannot ship a validated daemon; it can never satisfy the matrix"
fi

# 8) a custom release must require both explicit artifacts, then flow through
#    the same staged-byte pair gate checked above. Custom versions intentionally
#    set their expected core hash from RBF_PATH, so the old mismatch-block shape
#    no longer identifies this path.
custom_case=$(awk '/^  \*\)/,/^    ;;/ { print }' "$PKG")
if printf '%s\n' "$custom_case" | grep -q 'RBF_PATH' &&
   printf '%s\n' "$custom_case" | grep -q 'DAEMON_PATH' &&
   grep -q 'pair_core_md5=.*STAGE/cores/Plex.rbf' "$PKG" &&
   grep -q 'pair_daemon_md5=.*STAGE/bin/misterplexd' "$PKG"; then
  pass "custom pairs require explicit artifacts and staged bytes reach the pair policy"
else
  fail "custom pair path can avoid explicit artifacts or the staged-byte pair policy"
fi

# 9) Version matching must not let v0.4.10 impersonate immutable v0.4.1.
set +e
bad_version_out="$(VERSION=v0.4.10 "$PKG" 2>&1)"
bad_version_rc=$?
set -e
if [ "$bad_version_rc" -eq 1 ] &&
   printf '%s\n' "$bad_version_out" | grep -q 'unsupported release VERSION=v0.4.10'; then
  pass "v0.4.10 cannot select the immutable v0.4.1 pair by prefix"
else
  fail "version prefix collision selected v0.4.1 artifacts for v0.4.10 (rc=$bad_version_rc)"
fi

# 10) Plain make package must propagate one version to package and artifact gates.
if grep -Fq 'VERSION="$(VERSION)" $(ROOT)/scripts/package_release.sh' "$MAKEFILE" &&
   grep -Fq 'VERSION="$(VERSION)" REQUIRE_ARTIFACT=1 $(ROOT)/tests/unit/test_no_private_data.sh' "$MAKEFILE" &&
   grep -Fq 'VERSION="$(VERSION)" REQUIRE_ARTIFACT=1 $(ROOT)/tests/unit/test_release_rbf_hash.sh' "$MAKEFILE"; then
  pass "make package propagates one VERSION through packaging and verification"
else
  fail "make package does not propagate VERSION consistently"
fi

if [ "$fails" -eq 0 ]; then
  echo "test_release_pair_gate: OK"
  exit 0
fi
echo "test_release_pair_gate: FAILED ($fails)"
exit 1
