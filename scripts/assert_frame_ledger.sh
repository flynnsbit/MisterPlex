#!/usr/bin/env bash
# Assert soak frame-ledger integrity (promotion blocker P5).
#
# Usage:
#   scripts/assert_frame_ledger.sh <misterplexd.frame_ledger>
#   scripts/assert_frame_ledger.sh --self-test
#
# Identity over ALL session_end rows (survives process restarts):
#   sum(frames)-sum(presents)-sum(drops)-sum(present_fails) == sum(residual)
# residual total must be 0 for LEDGER_OK.
#
# Exit: 0 OK · 1 OPEN/missing · 2 usage · 3 RESTART_VISIBLE (residual still 0)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

self_test() {
  local td
  td=$(mktemp -d "$ROOT/build/fldXXXXXX")
  trap 'rm -rf "$td"' EXIT

  cat >"$td/open.ledger" <<'EOF'
ts=t event=process_start pid=100 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0 lifetime_present_fails=0
ts=t event=session_end pid=100 session=1 frames=4464 presents=4447 drops=1 present_fails=0 residual=16 closed=0 reason=stop
ts=t event=process_exit pid=100 code=0 why=sig uptime_s=196 lifetime_frames=4464 lifetime_presents=4447 lifetime_drops=1 lifetime_present_fails=0
EOF
  if "$0" "$td/open.ledger" >/dev/null 2>&1; then echo "SELF-TEST FAIL open"; exit 1; fi
  echo "SELF-TEST OK: open RED"

  cat >"$td/ok.ledger" <<'EOF'
ts=t event=process_start pid=100 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0 lifetime_present_fails=0
ts=t event=session_end pid=100 session=1 frames=7075 presents=7073 drops=2 present_fails=0 residual=0 closed=1 reason=eof
ts=t event=process_exit pid=100 code=0 why=sig uptime_s=300 lifetime_frames=7075 lifetime_presents=7073 lifetime_drops=2 lifetime_present_fails=0
EOF
  if ! "$0" "$td/ok.ledger" >/dev/null 2>&1; then echo "SELF-TEST FAIL closed"; exit 1; fi
  echo "SELF-TEST OK: closed GREEN"

  cat >"$td/restart.ledger" <<'EOF'
ts=t event=process_start pid=100 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0 lifetime_present_fails=0
ts=t event=session_end pid=100 session=1 frames=100 presents=100 drops=0 present_fails=0 residual=0 closed=1 reason=eof
ts=t event=process_exit pid=100 code=0 why=sig uptime_s=1543 lifetime_frames=100 lifetime_presents=100 lifetime_drops=0 lifetime_present_fails=0
ts=t event=process_start pid=200 lifetime_frames=0 lifetime_presents=0 lifetime_drops=0 lifetime_present_fails=0
ts=t event=session_end pid=200 session=1 frames=50 presents=49 drops=1 present_fails=0 residual=0 closed=1 reason=stop
ts=t event=process_exit pid=200 code=0 why=sig uptime_s=514 lifetime_frames=50 lifetime_presents=49 lifetime_drops=1 lifetime_present_fails=0
EOF
  set +e
  "$0" "$td/restart.ledger" >/dev/null 2>&1
  local rc=$?
  set -e
  if [[ "$rc" -ne 3 ]]; then echo "SELF-TEST FAIL multi rc=$rc want=3"; exit 1; fi
  echo "SELF-TEST OK: multi-process RESTART_VISIBLE rc=3"
  echo "assert_frame_ledger self-test PASS"
  exit 0
}

[[ "${1:-}" == "--self-test" ]] && self_test
[[ $# -lt 1 || ! -f "$1" ]] && { echo "usage: $0 <ledger>|--self-test" >&2; exit 2; }

OUT=$(LEDGER="$1" bash "$ROOT/scripts/print_frame_ledger.sh" 2>&1) || true
printf '%s\n' "$OUT"
echo "$OUT" | grep -q 'FAIL LEDGER_OPEN' && exit 1
echo "$OUT" | grep -qE 'FAIL LEDGER_MISSING|FAIL no session' && exit 1
if echo "$OUT" | grep -q 'RESTART_VISIBLE=1' && echo "$OUT" | grep -q 'LEDGER_OK'; then exit 3; fi
echo "$OUT" | grep -q 'LEDGER_OK' && exit 0
exit 1
