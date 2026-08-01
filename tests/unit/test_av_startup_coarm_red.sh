#!/usr/bin/env bash
# Static + mutation: tip sources MUST co-arm the A/V clock at the first video
# frame. A mutated copy that paces on the raw audible clock (no origin) must
# FAIL the same green checks — red-before-green and green-before-red.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
AV="$ROOT/host/libmisterplex/av_clock.hpp"
WORK="$ROOT/build/av-startup-coarm-unit"
mkdir -p "$WORK"

green_checks() {
  local mp="$1" av="$2"
  grep -q 'coArmedClockMs' "$av" || return 1
  grep -q 'simulateStartupPacer' "$av" || return 1
  grep -q 'audioClockOriginMs' "$mp" || return 1
  grep -q 'A/V co-arm first_frame=' "$mp" || return 1
  grep -q 'coArmedClockMs(raw, audioClockOriginMs)' "$mp" || return 1
  # Must not re-introduce "origin armed" solely on audio_active (the bug).
  if grep -q 'A/V origin armed audio_active=' "$mp"; then
    return 1
  fi
  return 0
}

if ! green_checks "$MP" "$AV"; then
  echo "FAIL: green A/V co-arm wiring checks failed on tip sources" >&2
  exit 1
fi
echo "PASS green: tip sources co-arm at first video frame"

cp "$MP" "$WORK/media_player.cpp"
cp "$AV" "$WORK/av_clock.hpp"

# RED TWIN: strip co-arm — pace on raw audible clock again.
sed -i 's/coArmedClockMs(raw, audioClockOriginMs)/raw \/*MUTANT no co-arm*\//' \
  "$WORK/media_player.cpp"
sed -i '/A\/V co-arm first_frame=/d' "$WORK/media_player.cpp"

if grep -q 'coArmedClockMs(raw, audioClockOriginMs)' "$WORK/media_player.cpp"; then
  echo "FAIL: red twin could not strip coArmedClockMs call" >&2
  exit 1
fi

set +e
green_checks "$WORK/media_player.cpp" "$WORK/av_clock.hpp"
RED_RC=$?
set -e
echo "av_startup_coarm_red_twin true rc=$RED_RC"
if [[ "$RED_RC" -eq 0 ]]; then
  echo "FAIL: red twin — green_checks still passed after stripping co-arm (vacuous)" >&2
  exit 1
fi
echo "PASS red twin: green_checks fail after co-arm strip (rc=$RED_RC)"

# Functional: rebuild test_avclock is already green; fault path is the sim itself.
# Rebuild avclock to ensure tip still passes (compile check).
CXX_BIN="${CXX:-g++}"
if [[ -n "${CXXFLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CXX_FLAGS=(${CXXFLAGS})
else
  CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra)
fi
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -o "$WORK/test_avclock_tip" \
  "$ROOT/tests/unit/test_avclock.cpp"
set +e
TIP_OUT="$("$WORK/test_avclock_tip" 2>&1)"
TIP_RC=$?
set -e
printf '%s\n' "$TIP_OUT"
echo "test_avclock_tip true rc=$TIP_RC"
if [[ "$TIP_RC" -ne 0 ]]; then
  echo "FAIL: tip test_avclock failed" >&2
  exit 1
fi

echo "OK av startup co-arm red/green gate"
