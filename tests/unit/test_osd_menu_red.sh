#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/osd-menu-red"
mkdir -p "$BUILD"
echo "Scope: OSD/idle renderer red-checks, including RBF identity display mutability"

CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206 # Match the Makefile convention: CXXFLAGS is a word list.
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra -I"$ROOT/host")
fi
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DOSD_MENU_FAULT_APPLY_INITIAL_IDLE \
  -o "$BUILD/test_osd_menu_fault" "$ROOT/tests/unit/test_osd_menu.cpp"

set +e
OUT="$("$BUILD/test_osd_menu_fault" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [[ "$RC" -eq 0 ]]; then
  echo "FAIL: OSD idle initial-snapshot fault unexpectedly passed" >&2
  exit 1
fi
grep -q "shouldApplyOsdIdle(false, 0x0000, 0x4000)" <<<"$OUT" || {
  echo "FAIL: OSD idle red-check did not hit initial 0x4000 baseline guard" >&2
  exit 1
}
echo "RED OK: initial 0x4000 OSD idle snapshot does not override IDLE_SCREEN"

rm -f "$BUILD/test_osd_menu_fallback_bitrate_fault"
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DOSD_MENU_FAULT_FALLBACK_624_BITRATE \
  -o "$BUILD/test_osd_menu_fallback_bitrate_fault" "$ROOT/tests/unit/test_osd_menu.cpp"
test -x "$BUILD/test_osd_menu_fallback_bitrate_fault" || {
  echo "FAIL: OSD 480p fallback bitrate mutant did not compile" >&2
  exit 1
}
echo "MUTANT_COMPILED: OSD 480p fallback bitrate"

set +e
OUT="$("$BUILD/test_osd_menu_fallback_bitrate_fault" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [[ "$RC" -eq 0 ]]; then
  echo "FAIL: OSD 480p fallback bitrate fault unexpectedly passed" >&2
  exit 1
fi
grep -q "weakBitrateKbpsForCodedSize(kPlex480pCodedWidth, kPlex480pCodedHeight)" <<<"$OUT" || {
  echo "FAIL: OSD 480p fallback bitrate red-check did not hit bitrate equality guard" >&2
  exit 1
}
echo "RED OK: OSD and fallback 480p coded geometry share one bitrate"

rm -f "$BUILD/test_osd_menu_rbf_id_constant_fault"
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DMISTERPLEX_FAULT_RBF_ID_LABEL_CONSTANT \
  -o "$BUILD/test_osd_menu_rbf_id_constant_fault" "$ROOT/tests/unit/test_osd_menu.cpp"
test -x "$BUILD/test_osd_menu_rbf_id_constant_fault" || {
  echo "FAIL: RBF identity constant-label mutant did not compile" >&2
  exit 1
}
echo "MUTANT_COMPILED: RBF identity label constant"

set +e
OUT="$("$BUILD/test_osd_menu_rbf_id_constant_fault" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [[ "$RC" -eq 0 ]]; then
  echo "FAIL: RBF identity constant-label fault unexpectedly passed" >&2
  exit 1
fi
grep -q "idDiff > 0" <<<"$OUT" || {
  echo "FAIL: RBF identity red-check did not hit two-build display-difference guard" >&2
  exit 1
}
echo "RED OK: two different RBF identifiers render different visible labels"
