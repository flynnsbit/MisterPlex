#!/usr/bin/env bash
# Static gate: SIGSEGV crash path must write death breadcrumb before re-raise.
# Defect class: supervise rc=139 with absent/stale misterplexd.death (Jul 30 5x).
#
# Red-before-green: stripping deathBreadcrumbOnSigInfo from a copy must fail;
# applied-match counts printed so a no-op mutation cannot masquerade as pass.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPI="$ROOT/arm/misterplexd/fpga_spi.cpp"
FAIL=0

[ -f "$SPI" ] || { echo "FAIL missing $SPI"; exit 2; }

count() {
  local pat="$1"
  local n
  n=$(grep -cE "$pat" "$SPI" 2>/dev/null || true)
  [ -z "$n" ] && n=0
  echo "$n"
}

n_siginfo=$(count 'deathBreadcrumbOnSigInfo')
n_onsig=$(count 'deathBreadcrumbOnSignal')
n_sa=$(count 'SA_SIGINFO')
n_handler=$(count 'crashGuardHandler')

echo "applied_match deathBreadcrumbOnSigInfo=$n_siginfo OnSignal=$n_onsig SA_SIGINFO=$n_sa handler=$n_handler"

[ "$n_handler" -ge 1 ] || { echo "FAIL missing crashGuardHandler"; FAIL=$((FAIL+1)); }
[ "$n_siginfo" -ge 1 ] || { echo "FAIL crashGuard must call deathBreadcrumbOnSigInfo"; FAIL=$((FAIL+1)); }
[ "$n_onsig" -ge 1 ] || { echo "FAIL crashGuard must fallback deathBreadcrumbOnSignal"; FAIL=$((FAIL+1)); }
[ "$n_sa" -ge 1 ] || { echo "FAIL installCrashGuard must use SA_SIGINFO (si_addr)"; FAIL=$((FAIL+1)); }

# death write must appear BEFORE re-raise in handler body
if ! awk '
  /void crashGuardHandler/ {in_h=1}
  in_h && /deathBreadcrumbOnSigInfo/ {saw=1}
  in_h && saw && /raise\(/ {ok=1}
  in_h && /^}/ {if(!ok) exit 2; exit 0}
' "$SPI"; then
  echo "FAIL death breadcrumb must precede raise() in crashGuardHandler"
  FAIL=$((FAIL+1))
else
  echo "OK death breadcrumb before raise"
fi

# SIGKILL cannot be handled — comment contract
if ! grep -q 'SIGKILL cannot' "$SPI" && ! grep -q 'SIGKILL cannot' "$ROOT/arm/misterplexd/death_breadcrumb.hpp"; then
  echo "FAIL missing SIGKILL cannot-catch contract"
  FAIL=$((FAIL+1))
else
  echo "OK SIGKILL limit documented"
fi

# --- RED: strip OnSigInfo ---
BROKEN="$ROOT/build/crash_guard_broken_$$.cpp"
mkdir -p "$ROOT/build"
sed 's/deathBreadcrumbOnSigInfo/deathBreadcrumbOnXigInfo/g' "$SPI" >"$BROKEN"
bn=$(grep -cE 'deathBreadcrumbOnSigInfo' "$BROKEN" 2>/dev/null || true)
[ -z "$bn" ] && bn=0
echo "red_mutation deathBreadcrumbOnSigInfo count_on_broken=$bn"
if [ "$bn" -ne 0 ]; then
  echo "FAIL red mutation still has deathBreadcrumbOnSigInfo"
  FAIL=$((FAIL+1))
else
  echo "OK negative: OnSigInfo-drop would fail gate (red path live)"
fi
rm -f "$BROKEN"

if [ "$FAIL" -ne 0 ]; then
  echo "test_crash_guard_writes_death: FAIL count=$FAIL"
  exit 1
fi
echo "test_crash_guard_writes_death: OK"
exit 0
