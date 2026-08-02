#!/usr/bin/env bash
# Host gate: OOM + RSS tools exist and encode honest MISS/NO-DATA contracts.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0

need() {
  local f="$1" pat="$2"
  if ! grep -qE "$pat" "$f"; then
    echo "FAIL $f missing /$pat/"
    FAIL=$((FAIL+1))
  else
    n=$(grep -cE "$pat" "$f" || true)
    echo "OK $f /$pat/ count=$n"
  fi
}

OOM="$ROOT/tools/oom_sigkill_probe.sh"
RSS="$ROOT/tools/rss_growth_sample.sh"
[ -x "$OOM" ] || { echo "FAIL not executable $OOM"; FAIL=$((FAIL+1)); }
[ -x "$RSS" ] || { echo "FAIL not executable $RSS"; FAIL=$((FAIL+1)); }

need "$OOM" 'MISS_is_not_proof_OOM_never_happened'
need "$OOM" 'RESULT=HIT_OOM_EVIDENCE_IN_LOG'
need "$OOM" 'RESULT=MISS_LOG_DOES_NOT_CONTAIN_OOM'
need "$OOM" 'exit 77'
need "$RSS" 'readlink -f'
need "$RSS" 'VmRSS'
need "$RSS" 'NO-DATA'
need "$RSS" 'MULTI_MATCH'

# RED: strip MISS honesty line
BROKEN="$ROOT/build/oom_broken_$$.sh"
mkdir -p "$ROOT/build"
sed 's/MISS_is_not_proof_OOM_never_happened/MISS_proves_no_oom/g' "$OOM" >"$BROKEN"
if grep -q 'MISS_is_not_proof_OOM_never_happened' "$BROKEN"; then
  echo "FAIL red mutation failed"
  FAIL=$((FAIL+1))
else
  echo "OK negative: honesty-line drop would fail gate"
fi
rm -f "$BROKEN"

if [ "$FAIL" -ne 0 ]; then
  echo "test_oom_rss_tools_static: FAIL count=$FAIL"
  exit 1
fi
echo "test_oom_rss_tools_static: OK"
exit 0
