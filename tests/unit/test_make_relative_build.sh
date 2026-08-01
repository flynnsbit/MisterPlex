#!/usr/bin/env bash
# Gate: `make build/<name>` must NOT be a silent no-op (parent 2026-08-01).
#
# Defect: Makefile targets are $(ROOT)/build/foo (absolute). Relative
# `make build/foo` matched nothing → "Nothing to be done" rc=0 with STALE
# binary — voids red-before-green.
#
# Prove: (1) relative make rebuilds when source is newer;
#         (2) after source mutation that fails the test, relative rebuild → RED;
#         (3) unknown relative target is loud fail (not rc=0 nothing-to-do).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; FAILS=$((FAILS + 1)); }

NAME=test_ffmpeg_vf
ABS="$ROOT/build/$NAME"
SRC="$ROOT/tests/unit/test_ffmpeg_vf.cpp"
HDR="$ROOT/host/libmisterplex/ffmpeg_vf.hpp"

# --- baseline build via RELATIVE form ---
rm -f "$ABS"
set +e
out=$(make -C "$ROOT" "build/$NAME" 2>&1)
rc=$?
set -e
echo "relative_fresh_build true rc=$rc"
echo "$out" | head -5
if [ "$rc" -ne 0 ] || [ ! -x "$ABS" ]; then
  fail "relative make build/$NAME did not produce binary (rc=$rc)"
elif echo "$out" | grep -q "Nothing to be done for .build/$NAME"; then
  fail "relative make still silent no-op on missing binary"
else
  pass "relative make build/$NAME builds binary"
fi

# --- stale-binary scenario: mutate source to fail, relative make must rebuild RED ---
BACKUP=$(mktemp "$ROOT/build/test_ffmpeg_vf.cpp.bak.XXXXXX")
cp "$SRC" "$BACKUP"
# Force a compile-time or link-time failure that still looks like a test change:
# inject #error so any rebuild cannot succeed silently with old binary.
printf '\n#error MAKE_RELATIVE_BUILD_MUTATION_FORCE_REBUILD\n' >>"$SRC"
# Ensure source is newer than binary
sleep 0.05
touch "$SRC"

set +e
out2=$(make -C "$ROOT" "build/$NAME" 2>&1)
rc2=$?
set -e
echo "relative_stale_mut true rc=$rc2"
# Restore source BEFORE any further builds
mv -f "$BACKUP" "$SRC"

if [ "$rc2" -eq 0 ]; then
  # If make returned 0, either it no-op'd (stale) or somehow compiled — both bad here.
  if echo "$out2" | grep -q "Nothing to be done"; then
    fail "STALE_NOOP: relative make ignored newer broken source (void red-before-green)"
  else
    fail "relative make rc=0 after #error mutation (expected rebuild fail)"
  fi
else
  if echo "$out2" | grep -q "MAKE_RELATIVE_BUILD_MUTATION_FORCE_REBUILD\|Error\|error:"; then
    pass "relative make rebuilds and goes RED on broken source (rc=$rc2)"
  else
    pass "relative make non-zero on broken source rc=$rc2 (rebuild attempted)"
  fi
fi

# Rebuild clean binary after restore
set +e
make -C "$ROOT" "build/$NAME" >/dev/null 2>&1
rc3=$?
set -e
echo "relative_restore true rc=$rc3"
if [ "$rc3" -eq 0 ] && [ -x "$ABS" ]; then
  pass "relative make restores green after source fix"
else
  fail "restore build failed rc=$rc3"
fi

# --- unknown target must not be silent success ---
set +e
outu=$(make -C "$ROOT" "build/this_target_does_not_exist_zz" 2>&1)
rcu=$?
set -e
echo "relative_unknown true rc=$rcu"
if [ "$rcu" -eq 0 ]; then
  fail "unknown build/* exited 0 (must fail loudly)"
elif echo "$outu" | grep -qiE 'No rule to make target|nothing to be done'; then
  # "Nothing to be done" on unknown would be the old bug if rc=0; rc!=0 is ok
  if echo "$outu" | grep -qi 'No rule to make target'; then
    pass "unknown build/* loud No rule (rc=$rcu)"
  else
    fail "unknown build/* unexpected: $outu"
  fi
else
  pass "unknown build/* non-zero rc=$rcu"
fi

# --- document void evidence class ---
echo "NOTE: any prior gate log that used \`make build/<name>\` before this fix"
echo "      and relied on rebuild is VOID — re-run with relative form now working,"
echo "      or use make \"\$(pwd)/build/<name>\"."

if [ "$FAILS" -ne 0 ]; then
  echo "FAIL test_make_relative_build failures=$FAILS" >&2
  exit 1
fi
echo "PASS test_make_relative_build"
exit 0
