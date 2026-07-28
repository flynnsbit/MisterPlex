#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/osd-menu-red"
mkdir -p "$BUILD"

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
