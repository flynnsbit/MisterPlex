#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$ROOT/scripts/test_resource_preflight.sh"
FIX="$ROOT/tests/fixtures/preflight"

# Synthetic host only: never inherit ambient override or live Quartus ps(1).
# MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1 is used by the fleet while a sibling map
# is LIVE; if this unit test inherits it, fail() exits 0 and the swap-exhausted
# red becomes vacuous. Live quartus_map similarly short-circuits every fixture
# before meminfo is read. Both must be isolated for the test to mean anything.
STUB_BIN="$ROOT/build/preflight-stub-bin"
rm -rf "$STUB_BIN"
mkdir -p "$STUB_BIN"
cleanup() { rm -rf "$STUB_BIN"; }
trap cleanup EXIT
cat >"$STUB_BIN/ps" <<'PS'
#!/bin/sh
# No processes — fixtures must not see the live host's quartus_map.
exit 0
PS
chmod +x "$STUB_BIN/ps"

run_preflight() {
  env -u MISTERPLEX_ALLOW_LOW_MEMORY_TESTS \
    PATH="$STUB_BIN:$PATH" \
    MISTERPLEX_PREFLIGHT_SAMPLE_SECONDS=1 \
    MISTERPLEX_PREFLIGHT_VMSTAT="$FIX/vmstat_quiet" \
    MISTERPLEX_PREFLIGHT_MEMINFO="$1" \
    "$PREFLIGHT"
}

run_preflight "$FIX/meminfo_high_headroom" >/dev/null
echo "PASS preflight accepts synthetic high-headroom host"

run_preflight "$FIX/meminfo_low_steady_state" >/dev/null
echo "PASS preflight accepts synthetic 6269MB steady-state host with swap slack"

set +e
LOW_OUT="$(run_preflight "$FIX/meminfo_swap_exhausted" 2>&1)"
LOW_RC=$?
set -e
printf '%s\n' "$LOW_OUT"
if [[ "$LOW_RC" -ne 3 ]]; then
  echo "FAIL preflight swap-exhausted fixture: got rc=$LOW_RC want rc=3" >&2
  exit 1
fi
if ! grep -q "swap free" <<<"$LOW_OUT"; then
  echo "FAIL preflight swap-exhausted fixture: refusal did not cite swap exhaustion" >&2
  exit 1
fi
echo "PASS preflight refuses synthetic swap-exhausted host"
