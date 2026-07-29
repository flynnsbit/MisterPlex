#!/usr/bin/env bash
# Prove coded vs presented strong types reject silent substitution at compile time,
# and that the correct typed program still builds and passes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/geometry-type-safety"
mkdir -p "$BUILD"

CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra -I"$ROOT/host")
fi

# --- Positive: correct program must compile fresh and pass ---
rm -f "$BUILD/geometry_type_ok"
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -o "$BUILD/geometry_type_ok" \
  "$ROOT/tests/unit/geometry_type_ok.cpp"
test -x "$BUILD/geometry_type_ok" || {
  echo "FAIL: geometry_type_ok did not produce an executable" >&2
  exit 1
}
OK_MTIME=$(stat -c %Y "$BUILD/geometry_type_ok")
NOW=$(date +%s)
# Binary must be fresh (built in this run), not a stale leftover.
if (( NOW - OK_MTIME > 60 )); then
  echo "FAIL: geometry_type_ok binary looks stale (mtime skew >60s)" >&2
  exit 1
fi
set +e
OUT="$("$BUILD/geometry_type_ok" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL: geometry_type_ok run rc=$RC" >&2
  exit 1
fi
grep -q 'test_geometry_type_ok: OK' <<<"$OUT" || {
  echo "FAIL: geometry_type_ok missing OK line" >&2
  exit 1
}
echo "GREEN OK: typed geometry program compiles and passes (rc=0)"

# --- Negative: presented-where-coded must fail to compile ---
BAD_OBJ="$BUILD/geometry_type_mismatch_coded_from_presented.o"
rm -f "$BAD_OBJ" "$BUILD/geometry_type_mismatch_coded_from_presented"
set +e
ERR="$("$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -c \
  -o "$BAD_OBJ" \
  "$ROOT/tests/unit/geometry_type_mismatch_coded_from_presented.cpp" 2>&1)"
BAD_RC=$?
set -e
printf '%s\n' "$ERR"
if [[ "$BAD_RC" -eq 0 ]]; then
  echo "FAIL: presented-as-coded mutant compiled (rc=0); type safety is vacuous" >&2
  exit 1
fi
if [[ -e "$BAD_OBJ" ]]; then
  echo "FAIL: mismatch object exists after failed compile" >&2
  exit 1
fi
# Require the diagnostic to mention the type mismatch (not a random include error).
if ! grep -Eq 'cannot convert|no matching function|wrong type|PresentedWidth|CodedWidth' <<<"$ERR"; then
  echo "FAIL: compile failed but diagnostic did not mention geometry type mismatch" >&2
  exit 1
fi
echo "RED OK: presented-where-coded rejected at compile time (rc=$BAD_RC)"
echo "test_geometry_type_safety: OK"
