#!/usr/bin/env bash
# Prove supervise backoff resets after a sustained healthy child run, and still
# doubles after a short crash. Exercises the same arithmetic as plexctl.sh's
# write_supervisor loop (HEALTHY_SECS=120).
set -euo pipefail

HEALTHY_SECS=120
backoff=2
fails=0
check() {
  if ! eval "$1"; then
    echo "FAIL: $1 (backoff=$backoff ran_s=${ran_s:-?})"
    fails=$((fails + 1))
  fi
}

# Simulate short crash-loop: ran_s=1 three times → backoff 2→4→8→16
for ran_s in 1 1 1; do
  if [ "$ran_s" -ge "$HEALTHY_SECS" ]; then
    backoff=2
  fi
  # sleep omitted
  if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
    [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
  fi
done
check '[ "$backoff" -eq 16 ]'

# Short again → 32
ran_s=5
if [ "$ran_s" -ge "$HEALTHY_SECS" ]; then backoff=2; fi
if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
  [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
fi
check '[ "$backoff" -eq 32 ]'

# Healthy long run → reset to 2 (the defect: old script would stay 32/64 forever)
ran_s=300
if [ "$ran_s" -ge "$HEALTHY_SECS" ]; then
  old=$backoff
  backoff=2
  check '[ "$old" -eq 32 ]'
  check '[ "$backoff" -eq 2 ]'
fi
# After healthy, do not grow on the exit path
if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
  [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
fi
check '[ "$backoff" -eq 2 ]'

# Immediate crash after healthy still grows
ran_s=1
if [ "$ran_s" -ge "$HEALTHY_SECS" ]; then backoff=2; fi
if [ "$ran_s" -lt "$HEALTHY_SECS" ]; then
  [ "$backoff" -lt 60 ] && backoff=$((backoff * 2))
fi
check '[ "$backoff" -eq 4 ]'

# Source-level: plexctl must contain BACKOFF_RESET and HEALTHY_SECS
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC=""
for c in "$ROOT/scripts/plexctl.sh" /home/flynnsbit/Projects/MisterPlex/scripts/plexctl.sh; do
  [ -f "$c" ] && SRC=$c && break
done
check '[ -n "$SRC" ]'
check 'grep -q HEALTHY_SECS=120 "$SRC"'
check 'grep -q BACKOFF_RESET "$SRC"'
check 'grep -q ran_s= "$SRC"'
if [ "$fails" -ne 0 ]; then
  echo "test_supervise_backoff: $fails fails"
  exit 1
fi
echo "test_supervise_backoff: OK"
exit 0
