#!/usr/bin/env bash
# Static + mutation: tip sources MUST hold MrAudio until first video frame and
# pace on raw audibleClock (no co-arm origin subtract). A mutated copy that
# either removes the gate or re-introduces co-arm origin must FAIL green_checks.
# Functional: test_avclock models real content offset (grabber-class metric).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
AV="$ROOT/host/libmisterplex/av_clock.hpp"
HPP="$ROOT/arm/misterplexd/media_player.hpp"
WORK="$ROOT/build/av-startup-hold-unit"
mkdir -p "$WORK"

green_checks() {
  local mp="$1" av="$2" hpp="$3"
  grep -q 'audioStartGate_' "$hpp" || return 1
  grep -q 'audio hold — buffering PCM until first video frame' "$mp" || return 1
  grep -q 'A/V audio_release first_frame=' "$mp" || return 1
  grep -q 'audioStartGate_.store(true' "$mp" || return 1
  grep -q 'realContentOffsetMs' "$av" || return 1
  grep -q 'HoldUntilVideo' "$av" || return 1
  grep -q 'StartupAudioMode' "$av" || return 1
  # Must not pace via co-arm origin subtract on the product path.
  if grep -q 'coArmedClockMs(raw, audioClockOriginMs)' "$mp"; then
    return 1
  fi
  if grep -q 'A/V co-arm first_frame=' "$mp"; then
    return 1
  fi
  return 0
}

if ! green_checks "$MP" "$AV" "$HPP"; then
  echo "FAIL: green A/V hold-until-video wiring checks failed on tip sources" >&2
  exit 1
fi
echo "PASS green: tip sources hold MrAudio until first video frame"

cp "$MP" "$WORK/media_player.cpp"
cp "$AV" "$WORK/av_clock.hpp"
cp "$HPP" "$WORK/media_player.hpp"

# RED TWIN A: strip gate open → product would leave audio stuck (checks must fail).
sed -i '/A\/V audio_release first_frame=/d' "$WORK/media_player.cpp"
sed -i 's/audioStartGate_.store(true, std::memory_order_release);/\/\*MUTANT no gate open*\//' \
  "$WORK/media_player.cpp"

set +e
green_checks "$WORK/media_player.cpp" "$WORK/av_clock.hpp" "$WORK/media_player.hpp"
RED_A=$?
set -e
echo "av_startup_hold_red_twin_gate true rc=$RED_A"
if [[ "$RED_A" -eq 0 ]]; then
  echo "FAIL: red twin A — green_checks still passed after stripping gate open" >&2
  exit 1
fi
echo "PASS red twin A: green_checks fail without audio_release (rc=$RED_A)"

# RED TWIN B: re-introduce co-arm origin call (the failed fix) — must fail.
cp "$MP" "$WORK/media_player.cpp"
# Inject a fake co-arm pace line so green_checks rejects it.
sed -i 's/clockMs = misterplex::audibleClockMs(/clockMs = misterplex::coArmedClockMs(raw, audioClockOriginMs); \/\/ MUTANT\n                        clockMs = misterplex::audibleClockMs(/' \
  "$WORK/media_player.cpp"
# Ensure the banned pattern is present for the checker.
if ! grep -q 'coArmedClockMs(raw, audioClockOriginMs)' "$WORK/media_player.cpp"; then
  echo '/* MUTANT */ clockMs = misterplex::coArmedClockMs(raw, audioClockOriginMs);' \
    >>"$WORK/media_player.cpp"
fi

set +e
green_checks "$WORK/media_player.cpp" "$WORK/av_clock.hpp" "$HPP"
RED_B=$?
set -e
echo "av_startup_hold_red_twin_coarm true rc=$RED_B"
if [[ "$RED_B" -eq 0 ]]; then
  echo "FAIL: red twin B — green_checks still passed with co-arm reintroduced" >&2
  exit 1
fi
echo "PASS red twin B: green_checks fail when co-arm origin returns (rc=$RED_B)"

# Functional: tip test_avclock must pass (includes coarm-real-offset RED proof).
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
# Require the co-arm real-offset trap to have fired in output (discriminating power).
if ! printf '%s\n' "$TIP_OUT" | grep -q 'startup_sim COARM'; then
  echo "FAIL: tip test_avclock did not print COARM real-offset line" >&2
  exit 1
fi
if ! printf '%s\n' "$TIP_OUT" | grep -q 'PASS startup hold-until-video'; then
  echo "FAIL: tip test_avclock missing hold-until-video PASS" >&2
  exit 1
fi

echo "OK av startup hold-until-video red/green gate"
