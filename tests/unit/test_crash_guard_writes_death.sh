#!/usr/bin/env bash
# Static gate: SIGSEGV crash path must write death breadcrumb before re-raise.
# Without this, supervise rc=139 leaves misterplexd.death absent/stale.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPI="$ROOT/arm/misterplexd/fpga_spi.cpp"
MAIN="$ROOT/arm/misterplexd/main.cpp"
FAIL=0

[ -f "$SPI" ] || { echo "FAIL missing $SPI"; exit 2; }

if ! grep -n 'deathBreadcrumbOnSignal' "$SPI" | grep -q .; then
  echo "FAIL crashGuard must call deathBreadcrumbOnSignal (SEGV witness)"
  FAIL=$((FAIL + 1))
else
  echo "OK crashGuard calls deathBreadcrumbOnSignal"
fi

if ! grep -n 'crashGuardHandler' "$SPI" | grep -q .; then
  echo "FAIL missing crashGuardHandler"
  FAIL=$((FAIL + 1))
fi

# SIGKILL cannot be handled — comment contract must stay honest.
if ! grep -q 'SIGKILL cannot' "$SPI" && ! grep -q 'SIGKILL cannot' "$ROOT/arm/misterplexd/death_breadcrumb.hpp"; then
  echo "FAIL missing SIGKILL cannot-catch contract"
  FAIL=$((FAIL + 1))
else
  echo "OK SIGKILL limit documented"
fi

# main captures sender ASAP after g_stop (before player.stop)
if ! grep -n 'deathBreadcrumbCaptureSender' "$MAIN" | grep -q .; then
  echo "FAIL main must call deathBreadcrumbCaptureSender after g_stop"
  FAIL=$((FAIL + 1))
else
  echo "OK main captures sender on g_stop"
fi

# Product loop still only exits via g_stop
sh "$ROOT/tests/unit/test_main_rc0_paths.sh" || FAIL=$((FAIL + 1))

if [ "$FAIL" -ne 0 ]; then
  echo "test_crash_guard_writes_death: FAIL count=$FAIL"
  exit 1
fi
echo "test_crash_guard_writes_death: OK"
exit 0
