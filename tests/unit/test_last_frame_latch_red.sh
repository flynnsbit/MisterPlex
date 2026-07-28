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

"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DLAST_FRAME_LATCH_FAULT_IDLE_GEOMETRY \
  -o "$BUILD/test_last_frame_latch_fault" "$ROOT/tests/unit/test_last_frame_latch.cpp"

set +e
OUT="$("$BUILD/test_last_frame_latch_fault" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT"
if [[ "$RC" -eq 0 ]]; then
  echo "FAIL: LastFrame idle-geometry fault unexpectedly passed" >&2
  exit 1
fi
grep -q "sentLayout.bank_stride == 0x40000u" <<<"$OUT" || {
  echo "FAIL: LastFrame red-check did not catch playback-geometry drift" >&2
  exit 1
}
echo "RED OK: LastFrame latch uses playback geometry, not idle/default geometry"
