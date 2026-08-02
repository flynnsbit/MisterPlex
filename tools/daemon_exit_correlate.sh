#!/bin/sh
# Read-only: pair supervise EXIT lines with daemon choke-points + death sender.
# Parent runs on device. Does not kill or restart anything.
#
# ROOT resolution (two-roots trap): live process via readlink -f /proc/*/exe,
# never sole hardcoded v1/v2. Override with ROOT= if needed (caller_supplied).
#
# Usage:
#   sh tools/daemon_exit_correlate.sh
#   ROOT=/media/fat/misterplex_v2 N=8 sh tools/daemon_exit_correlate.sh
#   sh tools/daemon_exit_correlate.sh; echo "true rc=$?"

set -u
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HERE/lib_live_misterplex_root.sh"

N=${N:-8}
if [ -n "${ROOT:-}" ]; then
  : # keep caller ROOT for helper
fi
if ! ROOT=$(resolve_live_misterplex_root); then
  echo "RESULT=NO-DATA reason=no_live_root"
  exit 77
fi
S=${SUPLOG:-$ROOT/misterplexd_supervise.log}
L=${DAEMON_LOG:-$ROOT/misterplexd.log}
D=${DEATH:-$ROOT/misterplexd.death}
DS=${DEATH_SENDER:-$ROOT/misterplexd.death.sender}
FL=${LEDGER:-$ROOT/misterplexd.frame_ledger}

echo "ROOT=$ROOT N=$N"

echo "=== death (latest) ==="
if [ -f "$D" ]; then cat "$D"; else echo "NO-DATA death (file absent)"; fi
echo "=== death.sender (latest capture) ==="
if [ -f "$DS" ]; then cat "$DS"; else echo "NO-DATA death.sender (file absent — pre-sender binary or no TERM exit yet)"; fi

echo "=== last $N supervise EXIT lines ==="
if [ -f "$S" ]; then
  grep -E 'EXIT pid=|SUPERVISE_EXIT' "$S" | tail -n "$N"
else
  echo "NO-DATA supervise log absent path=$S"
fi

echo "=== daemon EXIT_REASON / main_loop / SENDER_CAPTURE (last 40) ==="
if [ -f "$L" ]; then
  grep -E 'EXIT_REASON|main_loop exit pending|SENDER_CAPTURE|EXIT_REASON' "$L" | tail -n 40
else
  echo "NO-DATA daemon log absent path=$L"
fi

echo "=== last lines before each of last $N EXIT timestamps (best-effort) ==="
if [ -f "$S" ] && [ -f "$L" ]; then
  grep -E 'EXIT pid=' "$S" | tail -n "$N" | while IFS= read -r line; do
    ts=$(printf '%s' "$line" | awk '{print $1}')
    echo "-------- EXIT_TS=$ts --------"
    echo "$line"
    # Show EXIT_REASON lines whose ts= prefix matches this wall stamp hour:min
    # (string contains) — absence is "log does not contain", not "did not happen".
    hit=$(grep -E 'EXIT_REASON|main_loop exit pending|SENDER_CAPTURE' "$L" | grep -F "$ts" || true)
    if [ -n "$hit" ]; then
      printf '%s\n' "$hit"
    else
      echo "log_does_not_contain exact_ts=$ts in EXIT_REASON/main_loop/SENDER lines"
      # nearest: last 3 choke points overall before end (manual pairing aid)
    fi
  done
fi

echo "=== frame_ledger process boundaries (last 20) ==="
if [ -f "$FL" ]; then
  grep -E 'event=process_(start|exit)' "$FL" | tail -n 20
  echo "process_start_n=$(grep -c 'event=process_start' "$FL" || true)"
  echo "process_exit_n=$(grep -c 'event=process_exit' "$FL" || true)"
else
  echo "NO-DATA frame_ledger absent"
fi

echo "=== rc histogram (supervise) ==="
if [ -f "$S" ]; then
  grep -E 'EXIT pid=.*rc=' "$S" | sed -n 's/.*rc=\([0-9][0-9]*\).*/\1/p' | sort | uniq -c | sort -rn
else
  echo "NO-DATA"
fi

echo "daemon_exit_correlate done"
