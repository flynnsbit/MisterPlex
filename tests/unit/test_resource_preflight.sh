#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build/resource_preflight"
mkdir -p "$BUILD"
LOW_MEM="$BUILD/meminfo_low"
FULL_SWAP_IDLE="$BUILD/meminfo_full_swap_idle"
OK_MEM="$BUILD/meminfo_ok"
VM_IDLE="$BUILD/vmstat_idle"
VM_BUSY="$BUILD/vmstat_busy"
cat > "$LOW_MEM" <<'MEM'
MemTotal:       16384000 kB
MemFree:         1024000 kB
MemAvailable:   3072000 kB
Buffers:               0 kB
Cached:                0 kB
SwapTotal:       4194304 kB
SwapFree:              0 kB
MEM
cat > "$FULL_SWAP_IDLE" <<'MEM'
MemTotal:       16384000 kB
MemFree:         1024000 kB
MemAvailable:   5124096 kB
Buffers:               0 kB
Cached:                0 kB
SwapTotal:       4194304 kB
SwapFree:           5120 kB
MEM
cat > "$OK_MEM" <<'MEM'
MemTotal:       16384000 kB
MemFree:         8192000 kB
MemAvailable:   8192000 kB
Buffers:               0 kB
Cached:                0 kB
SwapTotal:       4194304 kB
SwapFree:        4194304 kB
MEM
cat > "$VM_IDLE" <<'VM'
pswpin 1000
pswpout 2000
pswpin 1000
pswpout 2000
VM
cat > "$VM_BUSY" <<'VM'
pswpin 1000
pswpout 2000
pswpin 1100
pswpout 2200
VM

set +e
LOW_OUT="$(MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$LOW_MEM" MISTERPLEX_TEST_PREFLIGHT_VMSTAT="$VM_IDLE" "$ROOT/scripts/test_resource_preflight.sh" unit 2>&1)"
LOW_RC=$?
set -e
printf '%s\n' "$LOW_OUT"
if [[ "$LOW_RC" -ne 75 ]]; then
  echo "FAIL resource preflight low-memory red-check: expected rc=75, got $LOW_RC" >&2
  exit 1
fi
if ! grep -q 'RESOURCE PREFLIGHT FAIL' <<<"$LOW_OUT"; then
  echo "FAIL resource preflight low-memory red-check: missing loud failure diagnostic" >&2
  exit 1
fi

set +e
BUSY_OUT="$(MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$OK_MEM" MISTERPLEX_TEST_PREFLIGHT_VMSTAT="$VM_BUSY" "$ROOT/scripts/test_resource_preflight.sh" unit 2>&1)"
BUSY_RC=$?
set -e
printf '%s\n' "$BUSY_OUT"
if [[ "$BUSY_RC" -ne 75 ]]; then
  echo "FAIL resource preflight swap-traffic red-check: expected rc=75, got $BUSY_RC" >&2
  exit 1
fi
if ! grep -q 'SwapTraffic:' <<<"$BUSY_OUT"; then
  echo "FAIL resource preflight swap-traffic red-check: missing swap traffic diagnostic" >&2
  exit 1
fi

MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$LOW_MEM" \
  MISTERPLEX_TEST_PREFLIGHT_VMSTAT="$VM_BUSY" \
  MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1 \
  "$ROOT/scripts/test_resource_preflight.sh" unit >/dev/null
MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$FULL_SWAP_IDLE" \
  MISTERPLEX_TEST_PREFLIGHT_VMSTAT="$VM_IDLE" \
  "$ROOT/scripts/test_resource_preflight.sh" unit >/dev/null
MISTERPLEX_TEST_PREFLIGHT_MEMINFO="$OK_MEM" \
  MISTERPLEX_TEST_PREFLIGHT_VMSTAT="$VM_IDLE" \
  "$ROOT/scripts/test_resource_preflight.sh" unit >/dev/null

echo "OK resource preflight red/green: low memory and active paging refuse; full-swap idle, override, and healthy fixture pass"
