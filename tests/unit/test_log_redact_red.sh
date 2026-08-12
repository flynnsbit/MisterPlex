#!/usr/bin/env bash
# EXPECTED_RED mutation: if redactSensitive becomes a no-op, green checks must FAIL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/unit/lib_expected_red.sh
. "$ROOT/tests/unit/lib_expected_red.sh"
BUILD="$ROOT/build/log-redact-red"
mkdir -p "$BUILD"

CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra)
fi

echo "=== test_log_redact_red EXECUTED (fault build only; not green) ==="

"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/arm/misterplexd" -DLOG_REDACT_FAULT_IDENTITY \
  -o "$BUILD/test_log_redact_identity_fault" \
  "$ROOT/tests/unit/test_log_redact.cpp"

set +e
OUT="$("$BUILD/test_log_redact_identity_fault" 2>&1)"
RC=$?
set -e
emit_expected_red_block "$OUT"

if [[ "$RC" -eq 0 ]]; then
  echo "FAIL: log_redact identity fault unexpectedly passed" >&2
  exit 1
fi

if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" log_redact_identity_fault "$RC" <<<"$OUT" 2>&1)"; then
  echo "$RED_CHECK" >&2
  echo "FAIL: log_redact EXPECTED_RED manifest check failed" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "RED OK: log_redact identity fault is caught"
