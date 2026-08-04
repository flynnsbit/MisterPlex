#!/usr/bin/env bash
# Static + mutation: tip sources MUST call applyRawVideoPipeSize on the video
# pipe; a mutated copy that drops the call must FAIL the same green checks.
# Red-before-green AND green-before-red — no vacuous "mutation detectable".
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=tests/unit/lib_expected_red.sh
. "$ROOT/tests/unit/lib_expected_red.sh"
MP="$ROOT/arm/misterplexd/media_player.cpp"
MAIN="$ROOT/arm/misterplexd/main.cpp"
HPP_LIB="$ROOT/host/libmisterplex/raw_video_pipe.hpp"
WORK="$ROOT/build/raw-video-pipe-unit"
mkdir -p "$WORK"

green_checks() {
  local mp="$1" main="$2" hpp="$3"
  # Helper exists with honest read-back contract.
  grep -q 'F_SETPIPE_SZ' "$hpp" || return 1
  grep -q 'F_GETPIPE_SZ' "$hpp" || return 1
  grep -q 'applyRawVideoPipeSize' "$hpp" || return 1
  grep -q 'formatRawVideoPipeLog' "$hpp" || return 1
  # Must not treat request as success without actual.
  grep -q 'actual' "$hpp" || return 1
  # media_player applies on the live video pipe read end.
  grep -q 'applyRawVideoPipeSize(vpipe\[0\]' "$mp" || return 1
  grep -q 'formatRawVideoPipeLog' "$mp" || return 1
  grep -q 'lastRawVideoPipeActual_' "$mp" || return 1
  # main conf + startup banner probe (read-back, not intent alone).
  grep -q 'RAW_VIDEO_PIPE_BYTES' "$main" || return 1
  grep -q 'applyRawVideoPipeSize' "$main" || return 1
  grep -q 'formatRawVideoPipeLog' "$main" || return 1
  # Absence of silent success: set_ok=0 path must exist in formatter.
  grep -q 'set_ok=0' "$hpp" || return 1
  return 0
}

echo "=== test_raw_video_pipe_red EXECUTED ==="
if ! green_checks "$MP" "$MAIN" "$HPP_LIB"; then
  echo "FAIL: green raw_video_pipe wiring checks failed on tip sources" >&2
  exit 1
fi
echo "PASS green: tip sources wire applyRawVideoPipeSize + conf + read-back log"

# RED TWIN: strip the live apply call from a temp media_player.cpp.
cp "$MP" "$WORK/media_player.cpp"
cp "$MAIN" "$WORK/main.cpp"
cp "$HPP_LIB" "$WORK/raw_video_pipe.hpp"

# Remove the apply block by blanking the apply line — green_checks must then fail.
sed -i 's/applyRawVideoPipeSize(vpipe\[0\], rawVideoPipeBytes_)/\/\*MUTANT\*\/ (void)rawVideoPipeBytes_; RawVideoPipeSizeResult{} /' \
  "$WORK/media_player.cpp"

if grep -q 'applyRawVideoPipeSize(vpipe\[0\]' "$WORK/media_player.cpp"; then
  echo "FAIL: red twin could not strip applyRawVideoPipeSize call" >&2
  exit 1
fi

set +e
green_checks "$WORK/media_player.cpp" "$WORK/main.cpp" "$WORK/raw_video_pipe.hpp"
RED_RC=$?
set -e
echo "raw_video_pipe_red_twin true rc=$RED_RC"
if [[ "$RED_RC" -eq 0 ]]; then
  echo "FAIL: red twin — green_checks still passed after stripping apply (vacuous)" >&2
  exit 1
fi
echo "PASS red twin: green_checks fail after apply strip (rc=$RED_RC)"

# Second red twin: formatter that always prints set_ok=1 must fail a string check.
# (static greps already require set_ok=0 path; mutate hpp to drop it)
sed -i 's/set_ok=0/set_ok=1/g' "$WORK/raw_video_pipe.hpp"
set +e
# restore mp apply so only hpp mutation is under test for this leg — re-copy tip mp
cp "$MP" "$WORK/media_player2.cpp"
# green_checks on mutated hpp should fail because set_ok=0 is gone
grep -q 'set_ok=0' "$WORK/raw_video_pipe.hpp"
HPP_HAS_FAIL=$?
set -e
echo "hpp_set_ok0_after_mutate true rc=$HPP_HAS_FAIL"
if [[ "$HPP_HAS_FAIL" -eq 0 ]]; then
  echo "FAIL: could not mutate away set_ok=0" >&2
  exit 1
fi
set +e
green_checks "$WORK/media_player2.cpp" "$WORK/main.cpp" "$WORK/raw_video_pipe.hpp"
RED2_RC=$?
set -e
echo "raw_video_pipe_red_twin_hpp true rc=$RED2_RC"
if [[ "$RED2_RC" -eq 0 ]]; then
  echo "FAIL: red twin hpp — green_checks passed without set_ok=0 path" >&2
  exit 1
fi
echo "PASS red twin hpp: green_checks fail without set_ok=0 path (rc=$RED2_RC)"

# Functional EXPECTED_RED: build the host test with RAW_PIPE_FAULT_NO_SET so
# F_SETPIPE_SZ is a no-op — the green binary MUST exit non-zero.
CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra)
fi
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -DRAW_PIPE_FAULT_NO_SET \
  -o "$WORK/test_raw_video_pipe_fault" \
  "$ROOT/tests/unit/test_raw_video_pipe.cpp"
set +e
FAULT_OUT="$("$WORK/test_raw_video_pipe_fault" 2>&1)"
FAULT_RC=$?
set -e
emit_expected_red_block "$FAULT_OUT"
echo "raw_video_pipe_fault true rc=$FAULT_RC"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL: RAW_PIPE_FAULT_NO_SET binary unexpectedly passed (vacuous green)" >&2
  exit 1
fi
echo "PASS functional red: fault binary rc=$FAULT_RC (green checks reject no-op set)"

echo "OK raw_video_pipe red/green static + functional gate"
