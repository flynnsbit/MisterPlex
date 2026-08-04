#!/usr/bin/env bash
# Red-before-green mutants for osd_menu.hpp.
# Fault binary stdout is prefixed EXPECTED_RED so make unit logs cannot be
# grepped as green FAIL (parent instrument class 2026-08-04).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/unit/lib_expected_red.sh
. "$ROOT/tests/unit/lib_expected_red.sh"
BUILD="$ROOT/build/osd-menu-red"
mkdir -p "$BUILD"

CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206 # Match the Makefile convention: CXXFLAGS is a word list.
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra -I"$ROOT/host")
fi

run_mutant() {
  local macro="$1"
  local bin="$2"
  local needle="$3"
  local ok_msg="$4"
  rm -f "$bin"
  "$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -D"$macro" \
    -o "$bin" "$ROOT/tests/unit/test_osd_menu.cpp"
  test -x "$bin" || {
    echo "FAIL: mutant $macro did not compile" >&2
    exit 1
  }
  echo "MUTANT_COMPILED: $macro"
  set +e
  OUT="$("$bin" 2>&1)"
  RC=$?
  set -e
  emit_expected_red_block "$OUT"
  if [[ "$RC" -eq 0 ]]; then
    echo "FAIL: mutant $macro unexpectedly passed (green path leak)" >&2
    exit 1
  fi
  grep -q "$needle" <<<"$OUT" || {
    echo "FAIL: mutant $macro did not hit expected assertion: $needle" >&2
    exit 1
  }
  echo "RED OK: $ok_msg"
}

echo "=== test_osd_menu_red EXECUTED (fault builds only; not green) ==="

run_mutant OSD_MENU_FAULT_SKIP_INITIAL_IDLE \
  "$BUILD/test_osd_menu_fault" \
  "shouldApplyOsdIdle(false, 0x0000, 0x4000)" \
  "skip-initial-idle mutant fails first-word persisted apply"

run_mutant OSD_MENU_FAULT_FALLBACK_624_BITRATE \
  "$BUILD/test_osd_menu_fallback_bitrate_fault" \
  "weakBitrateKbpsForCodedSize(kPlex480pCodedWidth, kPlex480pCodedHeight)" \
  "OSD and fallback 480p coded geometry share one bitrate"

run_mutant OSD_MENU_FAULT_CLAMP_720_BITRATE \
  "$BUILD/test_osd_menu_clamp720_fault" \
  "weakBitrateKbpsForCodedSize(CodedWidth{kPlex720pCodedWidth}" \
  "720p bitrate must not silent-clamp to 480p@2000"
