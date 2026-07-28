#!/usr/bin/env bash
# Unit coverage: the HDMI capture lock must be shared by ALL git worktrees.
#
# /dev/video0 is one physical device, but this repo runs ~20 linked git
# worktrees in parallel and each agent sources its own copy of
# hw_gate_common.sh.  When the lock file was derived from the worktree root
# ($root/build/video0.lock) every agent got a private lock and the mutual
# exclusion was decorative -- concurrent captures still collided on the device
# and surfaced as intermittent "Device or resource busy" capture failures.
#
# Anchoring the lock at `git rev-parse --git-common-dir` gives one lock per
# machine, because the common dir is identical for the main checkout and every
# linked worktree.
#
# Ships its green with its red: the same harness proves that distinct lock
# files do NOT serialise, which is exactly the old behaviour.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMON="$(cd "$ROOT" && cd "$(git rev-parse --git-common-dir)" && pwd)"
WORK="$ROOT/build/capture-lock-unit"
mkdir -p "$WORK"

fail() { echo "FAIL: $*" >&2; exit 1; }

PROBE="$WORK/probe.sh"
cat > "$PROBE" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$ROOT/tests/hw/hw_gate_common.sh"
capture_lock_acquire
sleep "\${1:-1}"
EOF
chmod +x "$PROBE"

# --- 1. default lock path lives under the shared git common dir -------------
OUT="$WORK/path.log"
CAPTURE_LOCK_TIMEOUT_S=5 "$PROBE" 0 > "$OUT" 2>&1
rc=$?
[[ $rc -eq 0 ]] || fail "probe could not acquire default lock rc=$rc: $(cat "$OUT")"
lock_line="$(grep -o 'CAPTURE_LOCK acquired: [^ ]*' "$OUT" | head -1)"
lock_path="${lock_line#CAPTURE_LOCK acquired: }"
[[ -n "$lock_path" ]] || fail "no CAPTURE_LOCK line emitted: $(cat "$OUT")"
if [[ "$lock_path" != "$COMMON/"* ]]; then
  fail "lock path '$lock_path' is not under the shared git common dir '$COMMON'; \
per-worktree locks do not serialise concurrent agents"
fi
case "$lock_path" in
  */.worktrees/*) fail "lock path '$lock_path' is inside a worktree; it must be shared" ;;
esac
echo "PASS default lock path is under the shared git common dir ($lock_path)"

# --- 2. GREEN: concurrent acquirers of the DEFAULT lock serialise -----------
CAPTURE_LOCK_TIMEOUT_S=10 "$PROBE" 4 > "$WORK/holder.log" 2>&1 &
holder=$!
sleep 1
CAPTURE_LOCK_TIMEOUT_S=1 "$PROBE" 0 > "$WORK/contender.log" 2>&1
crc=$?
wait "$holder"; hrc=$?
[[ $hrc -eq 0 ]] || fail "holder failed to take the lock rc=$hrc: $(cat "$WORK/holder.log")"
[[ $crc -eq 77 ]] || fail "contender should have been blocked with rc=77 (UNSCORED), got rc=$crc: $(cat "$WORK/contender.log")"
grep -q "could not acquire HDMI capture lock" "$WORK/contender.log" \
  || fail "contender did not report a lock timeout: $(cat "$WORK/contender.log")"
echo "PASS concurrent acquirers of the shared lock serialise (contender rc=77 UNSCORED)"

# --- 3. lock is released, so a later acquirer succeeds ----------------------
CAPTURE_LOCK_TIMEOUT_S=5 "$PROBE" 0 > "$WORK/after.log" 2>&1
[[ $? -eq 0 ]] || fail "lock was not released after holder exited: $(cat "$WORK/after.log")"
echo "PASS lock is released on exit (no permanent wedge)"

# --- 4. RED: distinct lock files do NOT serialise --------------------------
# This reproduces the old per-worktree behaviour and proves test 2 is real.
CAPTURE_LOCK_FILE="$WORK/lock_a" CAPTURE_LOCK_TIMEOUT_S=10 "$PROBE" 4 > "$WORK/red_a.log" 2>&1 &
red_holder=$!
sleep 1
CAPTURE_LOCK_FILE="$WORK/lock_b" CAPTURE_LOCK_TIMEOUT_S=1 "$PROBE" 0 > "$WORK/red_b.log" 2>&1
rrc=$?
wait "$red_holder"
[[ $rrc -eq 0 ]] || fail "red-check harness broken: distinct lock files should not block, rc=$rrc"
echo "PASS distinct lock files do NOT serialise (documents the old per-worktree bug)"

echo
echo "test_capture_lock_shared: OK (4 tests)"
