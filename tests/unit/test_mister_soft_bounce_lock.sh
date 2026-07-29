#!/usr/bin/env bash
# Mutation-prove mister_soft_bounce.sh lock exclusion + EXIT trap release.
# Local only — never touches the lab MiSTer (MISTER_CLAIM_SKIP_BOUNCE=1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BOUNCE="$ROOT/scripts/mister_soft_bounce.sh"
WORK="$ROOT/build/mister-soft-bounce-unit"
LOCK="$WORK/claim.lock"
LOG="$WORK/audit.log"
mkdir -p "$WORK"
rm -rf "$LOCK" "$LOG"

export MISTER_CLAIM_LOCK="$LOCK"
export MISTER_CLAIM_LOG="$LOG"
export MISTER_CLAIM_SKIP_BOUNCE=1
export MISTER_CLAIM_AGENT="unit-test-holder"
export MISTER_CLAIM_REASON="unit-lock-exclusion"

if [[ ! -x "$BOUNCE" ]]; then
  echo "FAIL: missing executable $BOUNCE" >&2
  exit 1
fi

# --- 1) First holder acquires and holds ---
"$BOUNCE" claim --hold-s 60 &
HOLDER_PID=$!

acquired=0
for _ in $(seq 1 50); do
  if [[ -d "$LOCK" && -f "$LOCK/pid" ]]; then
    acquired=1
    break
  fi
  sleep 0.05
done
if [[ "$acquired" != "1" ]]; then
  echo "FAIL: first holder never created lock at $LOCK" >&2
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  exit 1
fi
holder_recorded="$(cat "$LOCK/pid")"
if [[ "$holder_recorded" != "$HOLDER_PID" ]]; then
  echo "FAIL: lock pid=$holder_recorded want=$HOLDER_PID" >&2
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  exit 1
fi
echo "PASS first holder acquired lock pid=$HOLDER_PID"

# --- 2) Second acquisition MUST fail ---
set +e
"$BOUNCE" claim --agent unit-test-second --reason "should-be-excluded" --hold-s 1
SECOND_RC=$?
set -e
echo "second_claim true rc=$SECOND_RC"
if [[ "$SECOND_RC" -eq 0 ]]; then
  echo "FAIL: second claim unexpectedly succeeded" >&2
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  exit 1
fi
echo "PASS second claim excluded with non-zero rc=$SECOND_RC"

if [[ ! -d "$LOCK" ]]; then
  echo "FAIL: lock disappeared while first holder alive" >&2
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  exit 1
fi
still="$(cat "$LOCK/pid")"
if [[ "$still" != "$HOLDER_PID" ]]; then
  echo "FAIL: lock pid changed to $still while first holder alive" >&2
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  exit 1
fi
echo "PASS lock still owned by first holder after rejected second claim"

# --- 3) Trap releases on holder exit ---
kill "$HOLDER_PID"
set +e
wait "$HOLDER_PID"
HOLD_RC=$?
set -e
echo "holder_exit true rc=$HOLD_RC"

released=0
for _ in $(seq 1 50); do
  if [[ ! -d "$LOCK" ]]; then
    released=1
    break
  fi
  sleep 0.05
done
if [[ "$released" != "1" ]]; then
  echo "FAIL: EXIT trap did not release lock at $LOCK" >&2
  ls -la "$LOCK" >&2 || true
  exit 1
fi
echo "PASS EXIT trap released lock"

# --- 4) After release, a new claim succeeds ---
set +e
"$BOUNCE" claim --agent unit-test-third --reason "after-release" --hold-s 0
THIRD_RC=$?
set -e
echo "third_claim true rc=$THIRD_RC"
if [[ "$THIRD_RC" -ne 0 ]]; then
  echo "FAIL: third claim after release failed rc=$THIRD_RC" >&2
  exit 1
fi
if [[ -d "$LOCK" ]]; then
  echo "FAIL: third claim left lock behind after hold-s 0" >&2
  exit 1
fi
echo "PASS third claim after release succeeded and cleaned up"

# --- 5) Audit trail ---
if [[ ! -s "$LOG" ]]; then
  echo "FAIL: local audit log empty at $LOG" >&2
  exit 1
fi
grep -q "event=claim" "$LOG" || { echo "FAIL: audit missing claim" >&2; cat "$LOG" >&2; exit 1; }
grep -q "event=release" "$LOG" || { echo "FAIL: audit missing release" >&2; cat "$LOG" >&2; exit 1; }
echo "PASS local audit trail has claim+release"

# --- 6) Static deploy reuse ---
grep -q "DEPLOY_LOAD=menu" "$BOUNCE" || { echo "FAIL: no DEPLOY_LOAD=menu" >&2; exit 1; }
grep -q "DEPLOY_SKIP_COPY=1" "$BOUNCE" || { echo "FAIL: no DEPLOY_SKIP_COPY=1" >&2; exit 1; }
grep -q "deploy_plex_core.sh" "$BOUNCE" || { echo "FAIL: no deploy_plex_core.sh" >&2; exit 1; }
if grep -nE "/dev/MiSTer_cmd|printf.*load_core|echo.*load_core" "$BOUNCE" | grep -vE "[[:space:]]*#" >/dev/null; then
  echo "FAIL: bounce drives MiSTer_cmd/load_core directly" >&2
  exit 1
fi
grep -q "DEPLOY_SKIP_COPY" "$ROOT/scripts/deploy_plex_core.sh" || { echo "FAIL: deploy missing SKIP_COPY" >&2; exit 1; }
echo "PASS bounce reuses deploy menu path with SKIP_COPY (no RBF flash)"

# --- 7) CORENAME seizure ---
grep -q "verify_corename_plex" "$BOUNCE" || { echo "FAIL: missing verify_corename_plex" >&2; exit 1; }
grep -q "CORENAME_NOT_PLEX" "$BOUNCE" || { echo "FAIL: missing CORENAME_NOT_PLEX" >&2; exit 1; }
set +e
MISTER_CLAIM_FAKE_CORENAME="CD-CDPlayer" \
  "$BOUNCE" claim --agent unit-corename-seized --reason "corename-mutation" --hold-s 0 \
  >"$WORK/corename_seized.out" 2>"$WORK/corename_seized.err"
SEIZED_RC=$?
set -e
echo "corename_seized true rc=$SEIZED_RC"
if [[ "$SEIZED_RC" -eq 0 ]]; then
  echo "FAIL: claim succeeded with CORENAME=CD-CDPlayer" >&2
  cat "$WORK/corename_seized.out" "$WORK/corename_seized.err" >&2
  exit 1
fi
if [[ "$SEIZED_RC" -ne 5 ]]; then
  echo "FAIL: seized corename rc=$SEIZED_RC want rc=5" >&2
  cat "$WORK/corename_seized.out" "$WORK/corename_seized.err" >&2
  exit 1
fi
grep -q "CORENAME_NOT_PLEX" "$WORK/corename_seized.err" || { echo "FAIL: no CORENAME_NOT_PLEX" >&2; cat "$WORK/corename_seized.err" >&2; exit 1; }
grep -q "CD-CDPlayer" "$WORK/corename_seized.err" || { echo "FAIL: no CD-CDPlayer quote" >&2; cat "$WORK/corename_seized.err" >&2; exit 1; }
if [[ -d "$LOCK" ]]; then
  echo "FAIL: lock still held after corename seizure fail" >&2
  ls -la "$LOCK" >&2 || true
  exit 1
fi
grep -q "event=corename_fail" "$LOG" || { echo "FAIL: audit missing corename_fail" >&2; cat "$LOG" >&2; exit 1; }
echo "PASS CORENAME seizure (CD-CDPlayer) hard-fails rc=5 and audits"

: >"$LOG"
set +e
"$BOUNCE" claim --agent unit-corename-ok --reason "corename-ok" --hold-s 0
OK_RC=$?
set -e
echo "corename_ok true rc=$OK_RC"
if [[ "$OK_RC" -ne 0 ]]; then
  echo "FAIL: default CORENAME=Plex claim failed rc=$OK_RC" >&2
  exit 1
fi
grep -q "event=corename:" "$LOG" || { echo "FAIL: audit missing corename event" >&2; cat "$LOG" >&2; exit 1; }
grep -q "corename=Plex" "$LOG" || { echo "FAIL: audit missing corename=Plex" >&2; cat "$LOG" >&2; exit 1; }
echo "PASS CORENAME_OK audited as corename=Plex"

# --- 8) Progress lines on stdout ---
: >"$LOG"
TRACE="$WORK/trace.log"
rm -f "$TRACE"
set +e
MISTER_CLAIM_TRACE="$TRACE" \
  "$BOUNCE" claim --agent unit-progress --reason "progress-stdout" --hold-s 0 \
  >"$WORK/progress.out" 2>"$WORK/progress.err"
PROG_RC=$?
set -e
echo "progress_claim true rc=$PROG_RC"
if [[ "$PROG_RC" -ne 0 ]]; then
  echo "FAIL: progress claim rc=$PROG_RC" >&2
  cat "$WORK/progress.out" "$WORK/progress.err" >&2
  exit 1
fi
grep -q "step=lock_acquired" "$WORK/progress.out" || { echo "FAIL: stdout missing step=lock_acquired" >&2; cat "$WORK/progress.out" >&2; exit 1; }
grep -q "step=bounce_begin" "$WORK/progress.out" || { echo "FAIL: stdout missing step=bounce_begin" >&2; cat "$WORK/progress.out" >&2; exit 1; }
grep -q "step=lock_released" "$WORK/progress.out" || { echo "FAIL: stdout missing step=lock_released" >&2; cat "$WORK/progress.out" >&2; exit 1; }
if [[ ! -s "$TRACE" ]]; then
  echo "FAIL: trace log empty at $TRACE" >&2
  exit 1
fi
grep -q "step=lock_acquired" "$TRACE" || { echo "FAIL: trace missing lock_acquired" >&2; cat "$TRACE" >&2; exit 1; }
echo "PASS progress lines on stdout + trace log"

# --- 9) Mid-bounce TERM releases lock ---
rm -rf "$LOCK"
: >"$LOG"
set +e
MISTER_CLAIM_TEST_BOUNCE_SLEEP_S=30 \
  "$BOUNCE" claim --agent unit-mid-bounce-kill --reason "mid-bounce-kill" --hold-s 0 \
  >"$WORK/midbounce.out" 2>"$WORK/midbounce.err" &
MID_PID=$!
set -e

saw_lock=0
for _ in $(seq 1 100); do
  if [[ -d "$LOCK" && -f "$LOCK/pid" ]]; then
    saw_lock=1
    break
  fi
  sleep 0.05
done
if [[ "$saw_lock" != "1" ]]; then
  echo "FAIL: mid-bounce holder never created lock" >&2
  cat "$WORK/midbounce.out" "$WORK/midbounce.err" >&2 || true
  command kill -s TERM "$MID_PID" 2>/dev/null || true
  wait "$MID_PID" 2>/dev/null || true
  exit 1
fi
sleep 0.2
echo "mid-bounce holder pid=$MID_PID lock held; sending TERM"

command kill -s TERM "$MID_PID"
set +e
wait "$MID_PID"
MID_RC=$?
set -e
echo "mid_bounce_kill true rc=$MID_RC"

released=0
for _ in $(seq 1 100); do
  if [[ ! -d "$LOCK" ]]; then
    released=1
    break
  fi
  sleep 0.05
done
if [[ "$released" != "1" ]]; then
  echo "FAIL: mid-bounce TERM did not release lock at $LOCK" >&2
  ls -la "$LOCK" >&2 || true
  cat "$WORK/midbounce.out" "$WORK/midbounce.err" >&2 || true
  exit 1
fi
echo "PASS mid-bounce TERM released lock (true rc=$MID_RC)"

# --- 10) Static checks ---
for pat in \
  "timeout --foreground" \
  "ServerAliveCountMax=3" \
  "step(" \
  "trap cleanup EXIT INT TERM HUP" \
  "ensure_daemon" \
  "MISTER_CLAIM_RECOVER" \
  "MISTER_CLAIM_TEST_BOUNCE_SLEEP_S" \
  "SSH_TIMEOUT_S" \
  "BOUNCE_TIMEOUT_S" \
  "CLEANUP_TIMEOUT_S" \
  "RELEASE LOCK FIRST"
do
  grep -qF "$pat" "$BOUNCE" || { echo "FAIL: missing pattern: $pat" >&2; exit 1; }
done
grep -qE "trap.*HUP" "$BOUNCE" || { echo "FAIL: trap missing HUP" >&2; exit 1; }
if grep -nE "[[:space:]]BatchMode=yes|[[:space:]]-o BatchMode" "$BOUNCE" | grep -vE "[[:space:]]*#|do NOT set" >/dev/null; then
  echo "FAIL: BatchMode=yes breaks sshpass password auth" >&2
  grep -n "BatchMode" "$BOUNCE" >&2 || true
  exit 1
fi
python3 - "$BOUNCE" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
start = text.find("cleanup() {")
if start < 0:
    raise SystemExit("FAIL: cleanup() not found")
end = text.find("\ndo_claim()", start)
body = text[start: end if end > 0 else start + 3000]
rel = body.find("release_lock")
candidates = [i for i in (body.find("soft_bounce"), body.find("deploy_plex_core.sh")) if i >= 0]
rest = min(candidates) if candidates else -1
if rel < 0:
    raise SystemExit("FAIL: cleanup missing release_lock")
if rest >= 0 and rel > rest:
    raise SystemExit(f"FAIL: cleanup restore (pos {rest}) before release_lock (pos {rel})")
print("PASS cleanup orders release_lock before restore")
PY

echo "PASS static timeout/ssh/trap/ensure_daemon/recover checks"
echo "OK mister_soft_bounce lock exclusion + trap release + corename gate"
