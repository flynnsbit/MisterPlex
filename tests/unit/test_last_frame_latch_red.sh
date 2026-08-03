#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
  printf '%s\n' "$OUT"
  if [[ "$RC" -eq 0 ]]; then
    echo "FAIL: $label fault unexpectedly passed" >&2
    exit 1
  fi
  grep -q "$needle" <<<"$OUT" || {
    echo "FAIL: $label red-check did not hit expected relationship: $needle" >&2
    exit 1
  }
  echo "RED OK: $label"
}

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
