#!/usr/bin/env bash
# Host-only unit for tools/analyze_avsync_residual.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/analyze_avsync_residual.py"
OUT="$ROOT/build/analyze_avsync_residual_unit"
mkdir -p "$OUT"
pass=0
fail=0

check_rc() {
  local name="$1" expect="$2" got="$3"
  if [[ "$got" -eq "$expect" ]]; then
    echo "PASS $name rc expect=$expect true_rc=$got"
    pass=$((pass + 1))
  else
    echo "FAIL $name rc expect=$expect true_rc=$got"
    fail=$((fail + 1))
  fi
}

set +e
python3 "$TOOL" --self-test >"$OUT/self.txt" 2>&1
src=$?
set -e
echo "CASE self-test true_rc=$src"
check_rc self_test 0 "$src"
grep -q SELF_TEST_OK "$OUT/self.txt" && { echo "PASS banner"; pass=$((pass+1)); } || { echo "FAIL banner"; fail=$((fail+1)); }

# Empty → 77
set +e
python3 "$TOOL" >"$OUT/empty.txt" 2>&1
erc=$?
set -e
echo "CASE empty true_rc=$erc"
check_rc empty 77 "$erc"

echo "=== SUMMARY pass=$pass fail=$fail ==="
if [[ "$fail" -eq 0 ]]; then
  echo "ANALYZE_AVSYNC_RESIDUAL_OK pass=$pass"
  exit 0
fi
echo "ANALYZE_AVSYNC_RESIDUAL_FAIL"
exit 2
