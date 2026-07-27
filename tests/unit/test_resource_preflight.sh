#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build/resource_preflight"
mkdir -p "$BUILD"
LOW="$BUILD/meminfo_low"
OK="$BUILD/meminfo_ok"
cat > "$LOW" <<'MEM'
MemTotal:       16384000 kB
MemFree:         1024000 kB
MemAvailable:   3072000 kB
Buffers:               0 kB
Cached:                0 kB
SwapTotal:       4194304 kB
SwapFree:              0 kB
MEM
cat > "$OK" <<'MEM'
MemTotal:       16384000 kB
MemFree:         8192000 kB
MemAvailable:   8192000 kB
Buffers:               0 kB
Cached:                0 kB
SwapTotal:       4194304 kB
SwapFree:        4194304 kB
MEM
set +e
LOW_OUT="$(MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$LOW" "$ROOT/scripts/test_resource_preflight.sh" unit 2>&1)"
LOW_RC=$?
set -e
printf '%s\n' "$LOW_OUT"
if [[ "$LOW_RC" -eq 0 ]]; then
  echo "FAIL resource preflight red-check: low-memory fixture unexpectedly passed" >&2
  exit 1
fi
if [[ "$LOW_RC" -ne 75 ]]; then
  echo "FAIL resource preflight red-check: expected rc=75, got $LOW_RC" >&2
  exit 1
fi
if ! grep -q 'RESOURCE PREFLIGHT FAIL' <<<"$LOW_OUT"; then
  echo "FAIL resource preflight red-check: missing loud failure diagnostic" >&2
  exit 1
fi
MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$LOW" \
  MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1 \
  "$ROOT/scripts/test_resource_preflight.sh" unit >/dev/null
MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$OK" "$ROOT/scripts/test_resource_preflight.sh" unit >/dev/null
echo "OK resource preflight red/green: low-memory refuses, explicit override and healthy fixture pass"
