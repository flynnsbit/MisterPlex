#!/usr/bin/env bash
# RBG: absence-of-evidence must not become measured zero.
# Historic: build_rbf_remote `grep -c STA || true` → clean timing on missing report.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../scripts/lib/measure_status.inc.sh
source "$ROOT/scripts/lib/measure_status.inc.sh"
WORK="$ROOT/build/measure-status-three-way"
rm -rf "$WORK"
mkdir -p "$WORK"
pass=0
fail=0
ok() { echo "OK   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

echo "=== RED: absent STA → NO_DATA (not count 0) ==="
set +e
out=$(measure_sta_neg_slack "$WORK/missing.sta.rpt")
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
if [ "$rc" -eq 4 ] && echo "$out" | grep -q 'MEASURE_STATUS=NO_DATA'; then
  ok "absent STA is NO_DATA"
else
  bad "absent STA rc=$rc out=$out"
fi
if echo "$out" | grep -q 'MEASURE_COUNT=0'; then
  bad "absent STA must not emit MEASURE_COUNT=0"
else
  ok "absent STA has no fake zero count"
fi

echo "=== RED: historic collapse patterns (absence as measured zero) ==="
set +e
# build_rbf_remote used `|| true` — empty or zero; both are wrong claims of "measured".
collapsed_true=$(grep -cE ';[[:space:]]*-[0-9]+\.[0-9]+[[:space:]]*;' "$WORK/missing.sta.rpt" 2>/dev/null || true)
collapsed_echo0=$(grep -cE ';[[:space:]]*-[0-9]+\.[0-9]+[[:space:]]*;' "$WORK/missing.sta.rpt" 2>/dev/null || echo 0)
set -e
echo "  || true → '$collapsed_true'"
echo "  || echo 0 → '$collapsed_echo0'"
if [ "$collapsed_echo0" = "0" ]; then
  ok "historic || echo 0 collapses missing→0 (defect reproduced)"
else
  bad "expected || echo 0 → 0 got '$collapsed_echo0'"
fi
# || true must not be treated as a trustworthy measured zero either
if [ "$collapsed_true" = "0" ] || [ -z "$collapsed_true" ]; then
  ok "historic || true yields empty-or-zero (untrustworthy; not NO_DATA)"
else
  bad "unexpected || true result '$collapsed_true'"
fi

echo "=== GREEN: clean STA with zero negative rows → MEASURED count=0 ==="
# Minimal Quartus-like row without negative slack
cat >"$WORK/clean.sta.rpt" <<'STA'
; Setup Summary ;
; Clock ; Slack ; End Point TNS ;
; clk   ; 0.250 ; 0.000 ;
STA
set +e
out=$(measure_sta_neg_slack "$WORK/clean.sta.rpt")
rc=$?
set -e
echo "$out" | sed 's/^/  /'
echo "  true rc=$rc"
if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'MEASURE_STATUS=MEASURED' \
  && echo "$out" | grep -q 'MEASURE_COUNT=0'; then
  ok "clean STA measured zero negatives"
else
  bad "clean STA rc=$rc out=$out"
fi

echo "=== RED: STA with negative slack → MEASURED count>0 ==="
cat >"$WORK/neg.sta.rpt" <<'STA'
; Setup Summary ;
; Clock ; Slack ; End Point TNS ;
; clk   ; -0.123 ; -0.123 ;
STA
set +e
out=$(measure_sta_neg_slack "$WORK/neg.sta.rpt")
rc=$?
set -e
cnt=$(printf '%s\n' "$out" | sed -n 's/^MEASURE_COUNT=//p')
if [ "$rc" -eq 0 ] && [ "${cnt:-0}" -ge 1 ]; then
  ok "negative slack measured count=$cnt"
else
  bad "neg STA rc=$rc cnt=$cnt out=$out"
fi

echo "=== build_rbf_remote must not use grep -c STA || true ==="
src=$(cat "$ROOT/scripts/build_rbf_remote.sh")
if echo "$src" | grep -nE 'grep -cE.*sta.*\|\| true|NEG_SLACK_COUNT=.*\|\| true'; then
  # allow only in comments
  code=$(echo "$src" | grep -v '^\s*#' | grep -E 'grep -cE.*;[[:space:]]*-\|.*\|\| true' || true)
  if [ -n "$code" ]; then
    bad "build_rbf_remote still collapses STA count with || true"
  else
    ok "no active STA || true collapse"
  fi
else
  ok "no STA || true pattern"
fi
if echo "$src" | grep -q 'STA_ABSENT_OR_UNREADABLE\|measure_sta_neg_slack\|sta_absent_or_unreadable'; then
  ok "build_rbf_remote hard-fails absent STA"
else
  bad "build_rbf_remote missing STA absent hard-fail"
fi

echo "=== PASS=$pass FAIL=$fail ==="
if [ "$fail" -ne 0 ]; then
  echo "true rc=1"
  exit 1
fi
echo "true rc=0"
exit 0
