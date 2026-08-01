#!/usr/bin/env bash
# Host gate: at least one real main() rc=0 path emits EXIT_REASON (not silent).
# Path under test: misterplexd --help → deathBreadcrumbExit(0, site=main.cpp:--help).
# Product SIGTERM path is the same choke point (exitReported → deathBreadcrumbExit)
# but needs a running companion; --help is the cheap reproducible rc=0 site.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
make -s build/misterplexd
BIN="$ROOT/build/misterplexd"
ERR=$(mktemp "$ROOT/build/daemon_rc0_err.XXXXXX")
OUT=$(mktemp "$ROOT/build/daemon_rc0_out.XXXXXX")
cleanup() { rm -f "$ERR" "$OUT"; }
trap cleanup EXIT

set +e
"$BIN" --help >"$OUT" 2>"$ERR"
rc=$?
set -e
echo "misterplexd --help true rc=$rc"
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL expected rc=0 for --help"
  cat "$ERR" >&2 || true
  exit 1
fi
if ! grep -q 'EXIT_REASON code=0' "$ERR"; then
  echo "FAIL missing EXIT_REASON code=0 on stderr (silent rc=0 would hide product exits)"
  cat "$ERR" >&2 || true
  exit 1
fi
if ! grep -q 'site=main.cpp:--help' "$ERR"; then
  echo "FAIL EXIT_REASON why must name site=main.cpp:--help"
  cat "$ERR" >&2 || true
  exit 1
fi
echo "test_daemon_exit_rc0: OK"
exit 0
