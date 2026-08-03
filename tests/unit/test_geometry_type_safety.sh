#!/usr/bin/env bash
# Prove coded vs presented strong types reject silent substitution at compile time,
# and that conf/argv decode adoption rejects bare-int setDecodeSize + presented tags.
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

run_red() {
  local name="$1"
  local src="$2"
  local obj="$BUILD/${name}.o"
  rm -f "$obj" "$BUILD/$name"
  set +e
  local err bad_rc
  err="$("$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -c -o "$obj" "$src" 2>&1)"
  bad_rc=$?
  set -e
  printf '%s\n' "$err"
  if [[ "$bad_rc" -eq 0 ]]; then
    echo "FAIL: $name mutant compiled (rc=0); type safety is vacuous" >&2
    exit 1
  fi
  if [[ -e "$obj" ]]; then
    echo "FAIL: NO_OBJECT_AFTER_FAIL violated for $name" >&2
    exit 1
  fi
  echo "NO_OBJECT_AFTER_FAIL=1 name=$name"
  if ! grep -Eq 'cannot convert|no matching function|wrong type|PresentedWidth|CodedWidth|CodedHeight|CodedSize' <<<"$err"; then
    echo "FAIL: $name compile failed but diagnostic did not mention geometry type mismatch" >&2
    exit 1
  fi
  echo "RED OK: $name rejected at compile time (rc=$bad_rc)"
}

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

# --- Positive: conf/argv adopt policy ---
rm -f "$BUILD/test_coded_size_adopt"
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -o "$BUILD/test_coded_size_adopt" \
  "$ROOT/tests/unit/test_coded_size_adopt.cpp"
test -x "$BUILD/test_coded_size_adopt"
ADOPT_MTIME=$(stat -c %Y "$BUILD/test_coded_size_adopt")
NOW=$(date +%s)
if (( NOW - ADOPT_MTIME > 60 )); then
  echo "FAIL: test_coded_size_adopt binary looks stale" >&2
  exit 1
fi
set +e
ADOPT_OUT="$("$BUILD/test_coded_size_adopt" 2>&1)"
ADOPT_RC=$?
set -e
printf '%s\n' "$ADOPT_OUT"
if [[ "$ADOPT_RC" -ne 0 ]]; then
  echo "FAIL: test_coded_size_adopt run rc=$ADOPT_RC" >&2
  exit 1
fi
grep -q 'test_coded_size_adopt: OK' <<<"$ADOPT_OUT" || {
  echo "FAIL: test_coded_size_adopt missing OK line" >&2
  exit 1
}
echo "GREEN OK: test_coded_size_adopt compiles and passes (rc=0)"

# --- Negative mutants ---
run_red geometry_type_mismatch_coded_from_presented \
  "$ROOT/tests/unit/geometry_type_mismatch_coded_from_presented.cpp"
run_red geometry_type_mismatch_set_decode_bare_int \
  "$ROOT/tests/unit/geometry_type_mismatch_set_decode_bare_int.cpp"
run_red geometry_type_mismatch_set_decode_presented \
  "$ROOT/tests/unit/geometry_type_mismatch_set_decode_presented.cpp"

# Stronger: real MediaPlayer declaration rejects bare ints (header-only call).
MP_SRC="$BUILD/media_player_set_decode_bare_int.cpp"
cat >"$MP_SRC" <<'CPP'
#include "media_player.hpp"
void probe(misterplex::MediaPlayer& p) {
    int w = 624, h = 480;
    p.setDecodeSize(w, h); // must not compile
}
CPP
MP_OBJ="$BUILD/media_player_set_decode_bare_int.o"
rm -f "$MP_OBJ"
set +e
MP_ERR="$("$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -I"$ROOT/arm/misterplexd" -c \
  -o "$MP_OBJ" "$MP_SRC" 2>&1)"
MP_RC=$?
set -e
printf '%s\n' "$MP_ERR"
if [[ "$MP_RC" -eq 0 ]]; then
  echo "FAIL: MediaPlayer setDecodeSize(int,int) mutant compiled — hole reopened" >&2
  exit 1
fi
if [[ -e "$MP_OBJ" ]]; then
  echo "FAIL: NO_OBJECT_AFTER_FAIL violated for MediaPlayer bare-int mutant" >&2
  exit 1
fi
echo "NO_OBJECT_AFTER_FAIL=1 name=media_player_set_decode_bare_int"
if ! grep -Eq 'no matching function|cannot convert|CodedWidth|setDecodeSize' <<<"$MP_ERR"; then
  echo "FAIL: MediaPlayer mutant failed for unrelated reason" >&2
  exit 1
fi
echo "RED OK: MediaPlayer::setDecodeSize(int,int) rejected (rc=$MP_RC)"

echo "test_geometry_type_safety: OK"
