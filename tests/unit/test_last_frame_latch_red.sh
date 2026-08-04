#!/usr/bin/env bash
# Intentional RED twins for LastFrameLatch.
# Fault builds DEFINE macros that *must* trip green assertions.
# Lines "FAIL tests/unit/test_last_frame_latch.cpp:…" under EXPECTED_RED are
# intentional — NOT a green-unit failure.
# Control: ./build/test_last_frame_latch (no -DFAULT_*) → OK rc=0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tests/unit/lib_expected_red.sh
. "$ROOT/tests/unit/lib_expected_red.sh"
BUILD="$ROOT/build/last-frame-latch-red"
mkdir -p "$BUILD"

CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra -I"$ROOT/host")
fi

run_fault() {
  local exe="$1"
  local needle="$2"
  local label="$3"
  set +e
  OUT="$($exe 2>&1)"
  RC=$?
  set -e
  emit_expected_red_block "$OUT"
  if [[ "$RC" -eq 0 ]]; then
    echo "FAIL: $label fault unexpectedly passed (green binary would be OK; fault build must fail)" >&2
    exit 1
  fi
  grep -q "$needle" <<<"$OUT" || {
    echo "FAIL: $label red-check did not hit expected relationship: $needle" >&2
    exit 1
  }
  echo "RED OK: $label (intentional assertion fire under fault macro; green separate)"
}

echo "=== test_last_frame_latch_red EXECUTED (fault builds only; not green) ==="

"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DLAST_FRAME_LATCH_FAULT_IDLE_GEOMETRY \
  -o "$BUILD/test_last_frame_latch_idle_geometry_fault" \
  "$ROOT/tests/unit/test_last_frame_latch.cpp"
run_fault "$BUILD/test_last_frame_latch_idle_geometry_fault" \
  "s.frame_layout.bank_stride == capturedLayout.bank_stride" \
  "LastFrame latch uses playback geometry, not idle/default geometry"

"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DLAST_FRAME_LATCH_FAULT_BANK_BASE \
  -o "$BUILD/test_last_frame_latch_bank_base_fault" \
  "$ROOT/tests/unit/test_last_frame_latch.cpp"
run_fault "$BUILD/test_last_frame_latch_bank_base_fault" \
  "s.bank_phys == expectedPhys" \
  "LastFrame latch computes bank base from captured geometry stride"

echo "PASS test_last_frame_latch_red (both fault twins fired; green is separate binary)"
