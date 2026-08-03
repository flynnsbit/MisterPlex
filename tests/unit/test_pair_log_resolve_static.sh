#!/usr/bin/env bash
# RED/GREEN: pair script must not default to stale v1 misterplex log path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAIR="$ROOT/tools/avsync_pair_daemon_hdmi.sh"
INC="$ROOT/tools/avsync_live_log_resolve.inc.sh"
fail=0

echo "PRE-REGISTER: pair default uses live_log_resolve; no hardcoded v1-first default"

if [[ ! -f "$INC" ]]; then
  echo "FAIL missing $INC"
  exit 1
fi
if ! grep -q 'avsync_resolve_live_log' "$PAIR"; then
  echo "FAIL pair does not call avsync_resolve_live_log"
  fail=1
fi
if grep -qE 'DAEMON_LOG_REMOTE:-/media/fat/misterplex/misterplexd\.log' "$PAIR"; then
  echo "FAIL pair still defaults DAEMON_LOG_REMOTE to v1 path"
  fail=1
fi
if grep -q 'test -f .*/misterplex/misterplexd.log && tail' "$PAIR"; then
  echo "FAIL pair still has v1-first tail chain"
  fail=1
fi
# wait_session must also use include (parent two-roots)
if ! grep -q 'avsync_live_log_resolve.inc.sh' "$ROOT/tools/avsync_wait_session.sh"; then
  echo "FAIL wait_session missing live resolve include"
  fail=1
fi
# include puts v2 before v1 in fallback
if ! grep -A20 'if \[ -z "\$pick" \]' "$INC" | grep -n misterplex_v2 | head -1 | grep -q .; then
  echo "FAIL include fallback missing v2"
  fail=1
fi
# Order inside the fallback for-list only (ignore comments above).
fb=$(awk '/for f in \\/,/do$/' "$INC" || true)
if [[ -z "$fb" ]]; then
  fb=$(sed -n '/for f in \\/,+12p' "$INC")
fi
v2=$(printf '%s\n' "$fb" | grep -n 'misterplex_v2/misterplexd.log' | head -1 | cut -d: -f1)
v1=$(printf '%s\n' "$fb" | grep -n '/media/fat/misterplex/misterplexd.log' | head -1 | cut -d: -f1)
if [[ -z "$v2" || -z "$v1" || "$v2" -ge "$v1" ]]; then
  echo "FAIL fallback order v2=$v2 v1=$v1 (need v2 before v1)"
  echo "fallback_block<<"
  printf '%s\n' "$fb"
  echo ">>"
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL test_pair_log_resolve_static"
  exit 1
fi
echo "PASS test_pair_log_resolve_static"
exit 0
