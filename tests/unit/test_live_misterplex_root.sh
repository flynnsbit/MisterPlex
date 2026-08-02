#!/bin/sh
# Host gate: live root helper labels provenance; never silently prefers stale v1.
# Run: sh tests/unit/test_live_misterplex_root.sh; echo "true rc=$?"

set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
LIB="$ROOT_DIR/tools/lib_live_misterplex_root.sh"
. "$LIB"

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1) caller_supplied wins
out=$(ROOT="$tmp" resolve_live_misterplex_root 2>"$tmp/err1")
err=$(cat "$tmp/err1")
case "$err" in
  *root_source=caller_supplied*) ;;
  *) echo "FAIL expected caller_supplied got: $err"; fail=1 ;;
esac
[ "$out" = "$tmp" ] || { echo "FAIL ROOT path"; fail=1; }

# 2) NO-DATA when nothing live and no install (empty env, fake empty proc not needed —
#    on host without /media/fat installs we expect NO-DATA or FALLBACK if present)
unset ROOT || true
# Force no fallback by running in subshell with PATH only — still may find host misterplexd.
# Contract check: function returns 1 only when truly nothing; if host has install, FALLBACK ok.
set +e
out2=$(ROOT= resolve_live_misterplex_root 2>"$tmp/err2")
rc2=$?
set -e
err2=$(cat "$tmp/err2")
case "$err2" in
  *root_source=live_exe*|*root_source=FALLBACK_ASSUMED*|*root_source=NO-DATA*)
    ;;
  *)
    echo "FAIL unexpected provenance: $err2"
    fail=1
    ;;
esac
if [ "$rc2" -ne 0 ] && [ "$rc2" -ne 1 ]; then
  echo "FAIL unexpected rc=$rc2"
  fail=1
fi
if [ "$rc2" -eq 1 ]; then
  case "$err2" in
    *NO-DATA*) ;;
    *) echo "FAIL rc=1 must be NO-DATA: $err2"; fail=1 ;;
  esac
fi

# 3) correlate script sources helper (static)
grep -q 'lib_live_misterplex_root.sh' "$ROOT_DIR/tools/daemon_exit_correlate.sh" || {
  echo "FAIL daemon_exit_correlate must source live root helper"
  fail=1
}
grep -q 'ROOT=\${ROOT:-/media/fat/misterplex_v2}' "$ROOT_DIR/tools/daemon_exit_correlate.sh" && {
  echo "FAIL daemon_exit_correlate still hardcodes sole default ROOT=v2"
  fail=1
} || true

# 4) recvq sample must not hard-prefer stale v1 before live resolve
grep -q 'resolve_live_misterplex_log' "$ROOT_DIR/tools/pms_recvq_backlog_sample.sh" || {
  echo "FAIL pms_recvq_backlog_sample must use resolve_live_misterplex_log"
  fail=1
}

# 5) oom probe exists and sources helper
grep -q 'lib_live_misterplex_root.sh' "$ROOT_DIR/tools/oom_sigkill_probe.sh" || {
  echo "FAIL oom_sigkill_probe must source live root helper"
  fail=1
}

if [ "$fail" -ne 0 ]; then
  echo "RESULT=FAIL test_live_misterplex_root"
  exit 1
fi
echo "RESULT=PASS test_live_misterplex_root"
exit 0
