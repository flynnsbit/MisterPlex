#!/usr/bin/env bash
# Assert soak frame-ledger integrity from misterplexd logs (promotion blocker P5).
#
# Usage:
#   scripts/assert_frame_ledger.sh <misterplexd.log>
#   scripts/assert_frame_ledger.sh --self-test
#
# Rules (fail CLOSED — soft-skip is not a pass):
#   1. At least one media: ledger_end (or ledger_tick) line must exist.
#   2. Every ledger_end with decoded>0 must have closed=1 and unaccounted=0.
#   3. session_id must never decrease; a jump without a prior ledger_reset for
#      the new id is LEDGER_RESTART (visible — soak must not merge sessions).
#   4. If multiple session_ids appear, report RESTART_VISIBLE and require the
#      caller to treat the soak as multi-session (not one continuous ledger).
#
# Exit codes:
#   0  LEDGER_OK (single session, all ends closed)
#   1  LEDGER_OPEN or parse/invariant failure
#   2  usage / missing file
#   3  LEDGER_RESTART_VISIBLE (multiple sessions — not a silent pass)
set -euo pipefail

self_test() {
  local td
  td=$(mktemp -d)
  trap 'rm -rf "$td"' EXIT

  # RED: open ledger (the reviewer's ~16 unaccounted case)
  cat >"$td/open.log" <<'EOF'
media: ledger_reset session_id=1 pid=100 decoded=0 presented=0 pacer_drops=0 present_fails=0 unaccounted=0 closed=1 reason=stream_start
media: ledger_tick session_id=1 pid=100 decoded=1000 presented=983 pacer_drops=1 present_fails=0 unaccounted=16 closed=0
media: ledger_end session_id=1 pid=100 decoded=4464 presented=4447 pacer_drops=1 present_fails=0 unaccounted=16 closed=0
EOF
  if "$0" "$td/open.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: open ledger must be RED"; exit 1
  fi
  echo "SELF-TEST OK: open ledger RED"

  # GREEN: closed single session
  cat >"$td/ok.log" <<'EOF'
media: ledger_reset session_id=1 pid=100 decoded=0 presented=0 pacer_drops=0 present_fails=0 unaccounted=0 closed=1 reason=stream_start
media: ledger_tick session_id=1 pid=100 decoded=480 presented=479 pacer_drops=1 present_fails=0 unaccounted=0 closed=1
media: ledger_end session_id=1 pid=100 decoded=7075 presented=7073 pacer_drops=2 present_fails=0 unaccounted=0 closed=1
EOF
  if ! "$0" "$td/ok.log" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: closed ledger must be GREEN"; exit 1
  fi
  echo "SELF-TEST OK: closed ledger GREEN"

  # RESTART visible: two sessions
  cat >"$td/restart.log" <<'EOF'
media: ledger_reset session_id=1 pid=100 decoded=0 presented=0 pacer_drops=0 present_fails=0 unaccounted=0 closed=1 reason=stream_start
media: ledger_end session_id=1 pid=100 decoded=100 presented=100 pacer_drops=0 present_fails=0 unaccounted=0 closed=1
media: ledger_reset session_id=2 pid=200 decoded=0 presented=0 pacer_drops=0 present_fails=0 unaccounted=0 closed=1 reason=stream_start
media: ledger_end session_id=2 pid=200 decoded=50 presented=50 pacer_drops=0 present_fails=0 unaccounted=0 closed=1
EOF
  set +e
  "$0" "$td/restart.log" >/dev/null 2>&1
  local rc=$?
  set -e
  if [[ "$rc" -ne 3 ]]; then
    echo "SELF-TEST FAIL: multi-session must rc=3 got=$rc"; exit 1
  fi
  echo "SELF-TEST OK: multi-session RESTART_VISIBLE rc=3"
  echo "assert_frame_ledger self-test PASS"
  exit 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
fi

if [[ $# -lt 1 || ! -f "$1" ]]; then
  echo "usage: $0 <misterplexd.log> | $0 --self-test" >&2
  exit 2
fi
LOG="$1"

mapfile -t lines < <(grep -E 'media: ledger_(reset|tick|end) ' "$LOG" || true)
if [[ ${#lines[@]} -eq 0 ]]; then
  echo "FAIL LEDGER_MISSING: no media: ledger_* lines in $LOG"
  echo "NOTE: pre-ledger daemons cannot close the soak objection; deploy ledger build first."
  exit 1
fi

ends=0
open_ends=0
declare -A seen_reset
prev_sid=-1
sessions=()
max_unacct=0

for line in "${lines[@]}"; do
  sid=$(echo "$line" | sed -n 's/.*session_id=\([0-9][0-9]*\).*/\1/p')
  unacct=$(echo "$line" | sed -n 's/.*unaccounted=\(-*[0-9][0-9]*\).*/\1/p')
  closed=$(echo "$line" | sed -n 's/.*closed=\([01]\).*/\1/p')
  decoded=$(echo "$line" | sed -n 's/.*decoded=\([0-9][0-9]*\).*/\1/p')
  [[ -n "$sid" ]] || { echo "FAIL parse session_id: $line"; exit 1; }
  [[ -n "$unacct" ]] || unacct=0
  [[ -n "$closed" ]] || closed=0
  [[ -n "$decoded" ]] || decoded=0

  if [[ "$line" == *"ledger_reset"* ]]; then
    seen_reset[$sid]=1
  fi

  if [[ "$prev_sid" -ge 0 && "$sid" -lt "$prev_sid" ]]; then
    echo "FAIL LEDGER_SESSION_REGRESS session_id $prev_sid -> $sid"
    exit 1
  fi
  if [[ "$prev_sid" -ge 0 && "$sid" -gt "$prev_sid" && -z "${seen_reset[$sid]:-}" ]]; then
    echo "FAIL LEDGER_SESSION_JUMP without ledger_reset sid=$sid (prev=$prev_sid)"
    exit 1
  fi
  if [[ "$prev_sid" -ge 0 && "$sid" -ne "$prev_sid" ]]; then
    sessions+=("$sid")
  elif [[ "$prev_sid" -lt 0 ]]; then
    sessions+=("$sid")
  fi
  prev_sid=$sid

  if (( unacct < 0 )); then uabs=$((-unacct)); else uabs=$unacct; fi
  if (( uabs > max_unacct )); then max_unacct=$uabs; fi

  if [[ "$line" == *"ledger_end"* ]]; then
    ends=$((ends + 1))
    if (( decoded > 0 )) && { [[ "$closed" != "1" ]] || [[ "$unacct" != "0" ]]; }; then
      open_ends=$((open_ends + 1))
      echo "FAIL LEDGER_OPEN: $line"
    fi
  fi
done

# unique session count
uniq_sessions=$(printf '%s\n' "${sessions[@]}" | awk 'NF' | sort -nu | wc -l)

echo "ledger_lines=${#lines[@]} ledger_ends=$ends open_ends=$open_ends unique_sessions=$uniq_sessions max_abs_unaccounted=$max_unacct"

if (( open_ends > 0 )); then
  echo "FAIL LEDGER_OPEN count=$open_ends"
  exit 1
fi

if (( ends < 1 )); then
  # ticks only — require last tick closed if decoded>0
  last=$(printf '%s\n' "${lines[@]}" | grep 'ledger_tick' | tail -1 || true)
  if [[ -z "$last" ]]; then
    echo "FAIL LEDGER_MISSING_END: no ledger_end and no ledger_tick"
    exit 1
  fi
  unacct=$(echo "$last" | sed -n 's/.*unaccounted=\(-*[0-9][0-9]*\).*/\1/p')
  closed=$(echo "$last" | sed -n 's/.*closed=\([01]\).*/\1/p')
  decoded=$(echo "$last" | sed -n 's/.*decoded=\([0-9][0-9]*\).*/\1/p')
  if (( decoded > 0 )) && { [[ "$closed" != "1" ]] || [[ "$unacct" != "0" ]]; }; then
    echo "FAIL LEDGER_OPEN last_tick: $last"
    exit 1
  fi
fi

if (( uniq_sessions > 1 )); then
  echo "LEDGER_RESTART_VISIBLE unique_sessions=$uniq_sessions"
  echo "NOTE: do not merge counters across session_id; w-geom owns exit RCA."
  exit 3
fi

echo "LEDGER_OK unique_sessions=1 open_ends=0"
exit 0
