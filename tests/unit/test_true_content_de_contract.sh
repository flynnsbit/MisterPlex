#!/usr/bin/env bash
# True content-DE contract + RED twin (FAULT_ISLAND_PASSES).
# Product must PASS; fault build must fail island rejection (rc≠0) with EXECUTED.
set -euo pipefail

assert_exec() {
  local label="$1" log="$2"; shift 2
  local m missing=0
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
mkdir -p "$BUILD"
CXXFLAGS=(-std=c++17 -O2 -Wall -Wextra)

echo "=== PRODUCT true_content_de_contract ===" >&2
g++ "${CXXFLAGS[@]}" -o "$BUILD/test_true_content_de_contract" \
  "$ROOT/tests/unit/test_true_content_de_contract.cpp"
set +e
OUT="$("$BUILD/test_true_content_de_contract" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "product true rc=$RC"
assert_exec product "$OUT" \
  "CASE true_content_de_contract EXECUTED" \
  "PASS true_content_de_contract" \
  "CONTRACT true_960x540" \
  "CONTRACT island_960in1280x720" \
  "CHECK de_width_cycles == content_w" \
  "pred=T11/T21/T31/T41/T51"
[[ "$RC" -eq 0 ]] || exit 1

echo "=== RED FAULT_ISLAND_PASSES ===" >&2
g++ "${CXXFLAGS[@]}" -DFAULT_ISLAND_PASSES \
  -o "$BUILD/test_true_content_de_contract_fault_island" \
  "$ROOT/tests/unit/test_true_content_de_contract.cpp"
set +e
FOUT="$("$BUILD/test_true_content_de_contract_fault_island" 2>&1)"; FRC=$?
set -e
printf '%s\n' "$FOUT"
echo "fault_island true rc=$FRC"
assert_exec fault_island "$FOUT" "CASE true_content_de_contract EXECUTED"
if [[ "$FRC" -eq 0 ]]; then
  echo "FAIL: FAULT_ISLAND_PASSES must not PASS (red twin dead)" >&2
  exit 1
fi
echo "PASS red-check FAULT_ISLAND_PASSES true_rc=$FRC"

echo "OK true_content_de_contract product + RED island"
exit 0
