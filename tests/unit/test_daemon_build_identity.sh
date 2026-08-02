#!/usr/bin/env bash
# Guards daemon build identity.
#
# OBSERVED DEFECT CLASS: a deployed misterplexd was identifiable only by its
# binary md5 (the daily driver ran `ea643e99`). `git cat-file -t ea643e99` is
# "Not a valid object name" -- a build hash is not a commit -- so nobody could
# say what source the live device was running. That is how the parent spent a
# session reasoning off a stale (core, daemon) pair, and it blocks adding a
# hardware-validated row to scripts/pair_ship_policy.sh, because a matrix row
# for an untraceable binary cannot be reproduced.
#
# Assertions, each with a negative case a naive implementation would fail:
#   1. --version prints a revision and exits 0            (positive capability)
#   2. the revision MATCHES real git HEAD                 (a hardcoded string or
#      a permanent "unknown" passes 1 but fails this)
#   3. --version exits immediately, does NOT start the daemon (a naive impl that
#      falls through into the main loop passes 1 and 2 but hangs here)
#   4. the stamp is a real build dependency               (a bare -D never
#      retriggers a link, so the binary silently keeps an old revision)
#   5. no revision literal hardcoded in the source
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/misterplexd"
MAIN="$ROOT/arm/misterplexd/main.cpp"
MK="$ROOT/Makefile"
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

if [ ! -x "$BIN" ]; then
  echo "FAIL missing $BIN (build/misterplexd is a prerequisite of unit-unlocked)"
  exit 1
fi

# 1 + 3) capability, and it must terminate rather than boot the daemon.
# stdout carries the version line; stderr carries the exit breadcrumb.
timeout 20 "$BIN" --version > /tmp/.mplex_ver_out 2> /tmp/.mplex_ver_err; rc=$?
out="$(cat /tmp/.mplex_ver_out)"
err="$(cat /tmp/.mplex_ver_err)"
rm -f /tmp/.mplex_ver_out /tmp/.mplex_ver_err
if [ "$rc" -eq 124 ]; then
  fail "--version did not exit (timed out) -- it must not start the daemon"
elif [ "$rc" -ne 0 ]; then
  fail "--version exited rc=$rc: $out $err"
elif printf '%s' "$out" | grep -qE '^misterplexd git_rev=([0-9a-f]{12}(-dirty)?|unknown)$'; then
  pass "--version reports a revision and exits 0 ($out)"
else
  fail "--version stdout not in expected form: $out"
fi

# The exit must be catalogued by tests/unit/test_main_rc0_paths.sh, i.e. it must
# leave a breadcrumb naming its site -- never a silent bare return 0.
if printf '%s' "$err" | grep -q 'site=main.cpp:--version'; then
  pass "--version exit is breadcrumbed and catalogued"
else
  fail "--version exited without a site breadcrumb: $err"
fi

# The daemon must not have started a listener; if it had, rc would be 124 above.
if printf '%s' "$err$out" | grep -q "companion on :"; then
  fail "--version booted the companion listener instead of just printing"
else
  pass "--version did not start the daemon"
fi

# 2) the revision must be the REAL one. This is the assertion that a hardcoded
#    or permanently-"unknown" implementation fails inside a git checkout.
reported="$(printf '%s' "$out" | sed -n 's/.*git_rev=\([^ ]*\).*/\1/p')"
if git -C "$ROOT" rev-parse --short=12 HEAD >/dev/null 2>&1; then
  want="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
  [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] && want="${want}-dirty"
  if [ "$reported" = "$want" ]; then
    pass "reported revision matches git HEAD ($want)"
  else
    fail "reported '$reported' but git HEAD is '$want' (stale or hardcoded stamp)"
  fi
  if [ "$reported" = "unknown" ]; then
    fail "reported 'unknown' inside a git checkout"
  fi
else
  pass "not a git checkout; 'unknown' is the honest answer (skipping match)"
fi

# 4) the stamp must be a real dependency, not a bare -D that never relinks.
if grep -q 'MPLEX_BUILD_ID_H' "$MK" && \
   awk '/^MPLEX_HDR :=/,/^$/' "$MK" | grep -q 'MPLEX_BUILD_ID_H'; then
  pass "build-id header is a declared build dependency (MPLEX_HDR)"
else
  fail "build-id header is not in MPLEX_HDR; the stamp can go stale"
fi
if grep -qE '^\s*MPLEX_BUILD_DEFS\s*:?=.*MISTERPLEX_GIT_REV' "$MK"; then
  fail "revision passed only via -D; that never retriggers a link"
else
  pass "revision not injected via a dependency-less -D"
fi

# 5) no hardcoded revision literal in the source.
if grep -nE '#define[[:space:]]+MISTERPLEX_GIT_REV[[:space:]]+"[0-9a-f]{7,}"' "$MAIN" >/dev/null; then
  fail "main.cpp hardcodes a revision literal"
else
  pass "no hardcoded revision literal in main.cpp"
fi

# The startup banner must carry it too, so a running daemon's log identifies itself.
if grep -q 'running git_rev=%s' "$MAIN"; then
  pass "startup banner reports git_rev"
else
  fail "startup banner does not report git_rev"
fi

if [ "$fails" -eq 0 ]; then
  echo "test_daemon_build_identity: OK"
  exit 0
fi
echo "test_daemon_build_identity: FAILED ($fails)"
exit 1
