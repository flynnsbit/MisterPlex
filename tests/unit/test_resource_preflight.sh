#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT="$ROOT/scripts/test_resource_preflight.sh"
FIX="$ROOT/tests/fixtures/preflight"

run_preflight() {
  MISTERPLEX_PREFLIGHT_SAMPLE_SECONDS=1 \
  MISTERPLEX_PREFLIGHT_VMSTAT="$FIX/vmstat_quiet" \
  MISTERPLEX_PREFLIGHT_MEMINFO="$1" \
  "$PREFLIGHT"
}

run_preflight "$FIX/meminfo_high_headroom" >/dev/null
echo "PASS preflight accepts synthetic high-headroom host"

set +e
LOW_OUT="$(run_preflight "$FIX/meminfo_low_steady_state" 2>&1)"
LOW_RC=$?
set -e
printf '%s\n' "$LOW_OUT"
if [[ "$LOW_RC" -ne 3 ]]; then
  echo "FAIL preflight low-headroom fixture: got rc=$LOW_RC want rc=3" >&2
  exit 1
fi
if ! grep -q "below 8192MB absolute headroom floor" <<<"$LOW_OUT"; then
  echo "FAIL preflight low-headroom fixture: refusal did not cite absolute headroom" >&2
  exit 1
fi
echo "PASS preflight refuses synthetic steady-state low-headroom host"
