#!/usr/bin/env bash
# restore_misterplexd_prev.sh must HARD REFUSE (rc=10), never silent success.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
set +e
"$ROOT/scripts/restore_misterplexd_prev.sh" >"$ROOT/.agent-work/w-lint/restore_unit.out" 2>&1
rc=$?
set -e
echo "restore_misterplexd_prev true rc=$rc"
if [[ "$rc" -ne 10 ]]; then
  echo "FAIL expected rc=10 REFUSE, got $rc"
  exit 1
fi
grep -q "REFUSE HALF_RESTORE" "$ROOT/.agent-work/w-lint/restore_unit.out" \
  || { echo "FAIL missing REFUSE HALF_RESTORE"; exit 1; }
grep -q "rollback_v2.sh" "$ROOT/.agent-work/w-lint/restore_unit.out" \
  || { echo "FAIL missing rollback_v2 pointer"; exit 1; }
echo "PASS restore refuses half-transition rc=10"
exit 0
