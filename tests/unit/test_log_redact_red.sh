#!/usr/bin/env bash
# EXPECTED_RED mutation: if redactSensitive becomes a no-op, green checks must FAIL.
# Binary lives under build/log-redact-red/ — never overwrites green build/test_log_redact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/log-redact-red"
mkdir -p "$BUILD"

CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra)
fi
# Drop a polluted -DLOG_REDACT_FAULT_IDENTITY from env, then add it once explicitly.
FILTERED=()
for f in "${CXX_FLAGS[@]}"; do
  [[ "$f" == "-DLOG_REDACT_FAULT_IDENTITY" || "$f" == "-DLOG_REDACT_FAULT_IDENTITY=1" ]] && continue
  FILTERED+=("$f")
done
CXX_FLAGS=("${FILTERED[@]}")

"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/arm/misterplexd" -DLOG_REDACT_FAULT_IDENTITY \
  -o "$BUILD/test_log_redact_identity_fault" \
  "$ROOT/tests/unit/test_log_redact.cpp"

set +e
OUT="$("$BUILD/test_log_redact_identity_fault" 2>&1)"
RC=$?
set -e
# Prefix so make-unit greps for bare green FAILs do not treat the twin as product red.
while IFS= read -r line; do
  printf 'EXPECTED_RED_LOG_REDACT_TWIN %s\n' "$line"
done <<<"$OUT"

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
