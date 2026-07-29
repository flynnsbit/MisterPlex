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

# --- 1) First holder acquires and holds (long enough for exclusion probe) ---
"$BOUNCE" claim --hold-s 60 &
HOLDER_PID=$!

# Wait until lock dir exists (bounded)
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

# --- 2) Second acquisition MUST fail with captured non-zero rc ---
set +e
"$BOUNCE" claim --agent unit-test-second --reason "should-be-excluded" --hold-s 1
SECOND_RC=$?
set -e
echo "second_claim true rc=$SECOND_RC"
if [[ "$SECOND_RC" -eq 0 ]]; then
  echo "FAIL: second claim unexpectedly succeeded (lock did not exclude)" >&2
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  exit 1
fi
if [[ "$SECOND_RC" -eq 0 ]]; then
  : # unreachable; kept for clarity
fi
echo "PASS second claim excluded with non-zero rc=$SECOND_RC"

# Lock must still be held by the first owner
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

# Give trap a moment to rm the lock dir
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

# --- 5) Audit trail local lines exist ---
if [[ ! -s "$LOG" ]]; then
  echo "FAIL: local audit log empty at $LOG" >&2
  exit 1
fi
grep -q 'event=claim' "$LOG" || {
  echo "FAIL: audit log missing claim events" >&2
  cat "$LOG" >&2
  exit 1
}
grep -q 'event=release' "$LOG" || {
  echo "FAIL: audit log missing release events" >&2
  cat "$LOG" >&2
  exit 1
}
echo "PASS local audit trail has claim+release"

# --- 6) Static: bounce path reuses deploy menu + SKIP_COPY (no invented loader) ---
grep -q 'DEPLOY_LOAD=menu' "$BOUNCE" || {
  echo "FAIL: bounce script does not reference DEPLOY_LOAD=menu" >&2
  exit 1
}
grep -q 'DEPLOY_SKIP_COPY=1' "$BOUNCE" || {
  echo "FAIL: bounce script does not set DEPLOY_SKIP_COPY=1" >&2
  exit 1
}
grep -q 'deploy_plex_core.sh' "$BOUNCE" || {
  echo "FAIL: bounce script does not call deploy_plex_core.sh" >&2
  exit 1
}
# Must not drive /dev/MiSTer_cmd or issue load_core itself — only call deploy.
if grep -nE '/dev/MiSTer_cmd|printf.*load_core|echo.*load_core' "$BOUNCE" \
  | grep -vE '[[:space:]]*#' >/dev/null; then
  echo "FAIL: bounce script drives MiSTer_cmd/load_core directly (must reuse deploy)" >&2
  grep -nE '/dev/MiSTer_cmd|load_core' "$BOUNCE" >&2 || true
  exit 1
fi
grep -q 'DEPLOY_SKIP_COPY' "$ROOT/scripts/deploy_plex_core.sh" || {
  echo "FAIL: deploy_plex_core.sh missing DEPLOY_SKIP_COPY support" >&2
  exit 1
}
echo "PASS bounce reuses deploy menu path with SKIP_COPY (no RBF flash)"

# --- 7) Post-bounce CORENAME must be Plex; non-Plex is a loud hard fail ---
grep -q 'verify_corename_plex' "$BOUNCE" || {
  echo "FAIL: bounce script missing verify_corename_plex" >&2
  exit 1
}
grep -q 'CORENAME_NOT_PLEX' "$BOUNCE" || {
  echo "FAIL: bounce script missing CORENAME_NOT_PLEX loud error" >&2
  exit 1
}
# Default SKIP_BOUNCE path synthesizes Plex → claim succeeds (already covered).
# Inject CD-CDPlayer (lab physical-CD seizure class) → must fail non-zero.
set +e
MISTER_CLAIM_FAKE_CORENAME='CD-CDPlayer' \
  "$BOUNCE" claim --agent unit-corename-seized --reason "corename-mutation" --hold-s 0 \
  >"$WORK/corename_seized.out" 2>"$WORK/corename_seized.err"
SEIZED_RC=$?
set -e
echo "corename_seized true rc=$SEIZED_RC"
if [[ "$SEIZED_RC" -eq 0 ]]; then
  echo "FAIL: claim succeeded with CORENAME=CD-CDPlayer (seizure not detected)" >&2
  cat "$WORK/corename_seized.out" "$WORK/corename_seized.err" >&2
  exit 1
fi
if [[ "$SEIZED_RC" -ne 5 ]]; then
  echo "FAIL: seized corename rc=$SEIZED_RC want rc=5" >&2
  cat "$WORK/corename_seized.out" "$WORK/corename_seized.err" >&2
  exit 1
fi
grep -q 'CORENAME_NOT_PLEX' "$WORK/corename_seized.err" || {
  echo "FAIL: seized corename did not print CORENAME_NOT_PLEX" >&2
  cat "$WORK/corename_seized.err" >&2
  exit 1
}
grep -q 'CD-CDPlayer' "$WORK/corename_seized.err" || {
  echo "FAIL: seized corename error did not quote CD-CDPlayer" >&2
  cat "$WORK/corename_seized.err" >&2
  exit 1
}
# Lock must not be left held after failed claim (trap release)
if [[ -d "$LOCK" ]]; then
  echo "FAIL: lock still held after corename seizure fail" >&2
  ls -la "$LOCK" >&2 || true
  exit 1
fi
grep -q 'event=corename_fail' "$LOG" || {
  echo "FAIL: audit log missing corename_fail after seizure" >&2
  cat "$LOG" >&2
  exit 1
}
echo "PASS CORENAME seizure (CD-CDPlayer) hard-fails rc=5 and audits"

# Green path still records corename=Plex in audit after a clean claim
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
grep -q 'event=corename:' "$LOG" || {
  echo "FAIL: audit missing corename event on green path" >&2
  cat "$LOG" >&2
  exit 1
}
grep -q 'corename=Plex' "$LOG" || {
  echo "FAIL: audit missing corename=Plex on green path" >&2
  cat "$LOG" >&2
  exit 1
}
echo "PASS CORENAME_OK audited as corename=Plex"

echo "OK mister_soft_bounce lock exclusion + trap release + corename gate"
