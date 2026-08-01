#!/usr/bin/env bash
# Static + mutation: tip sources MUST hold MrAudio until first video frame,
# assert content_origin_ms=0 at release, re-arm hold on seek/auto-next sessions
# (via play() → new audioPump), and NOT re-arm on pause/resume.
# Functional: test_avclock models real content offset + multi-session + no-video.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
AV="$ROOT/host/libmisterplex/av_clock.hpp"
HPP="$ROOT/arm/misterplexd/media_player.hpp"
MAIN="$ROOT/arm/misterplexd/main.cpp"
WORK="$ROOT/build/av-startup-hold-unit"
mkdir -p "$WORK"

green_checks() {
  local mp="$1" av="$2" hpp="$3" main="$4"
  grep -q 'audioStartGate_' "$hpp" || return 1
  grep -q 'audio hold — buffering PCM until first video frame' "$mp" || return 1
  grep -q 'content_origin_ms=0' "$mp" || return 1
  grep -q 'checkAudioReleaseOrigin' "$mp" || return 1
  grep -q 'A/V audio_release first_frame=' "$mp" || return 1
  grep -q 'audioStartGate_.store(true' "$mp" || return 1
  grep -q 'no auto-release without video' "$mp" || return 1
  grep -q 'kAudioHoldCapBytes' "$av" || return 1
  grep -q 'realContentOffsetMs' "$av" || return 1
  grep -q 'HoldUntilVideo' "$av" || return 1
  grep -q 'handoffReArmsAudioHold' "$av" || return 1
  grep -q 'simulateMultiSessionStartup' "$av" || return 1
  grep -q 'simulatePauseResumeHold' "$av" || return 1
  grep -q 'simulateHoldNoVideo' "$av" || return 1
  # seek restarts via play() (new session) — hold re-arms on that path.
  grep -q 'play(withUniversalOffset' "$mp" || return 1
  # auto-next goes through doPlay → player.play (new session).
  grep -q 'tryAutoNext' "$main" || return 1
  grep -q 'doPlay' "$main" || return 1
  # pause/resume must NOT touch audioStartGate_.
  if grep -n 'void MediaPlayer::pause' -A20 "$mp" | grep -q 'audioStartGate_'; then
    return 1
  fi
  if grep -n 'void MediaPlayer::resume' -A20 "$mp" | grep -q 'audioStartGate_'; then
    return 1
  fi
  # Must not pace via co-arm origin subtract on the product path.
  if grep -q 'coArmedClockMs(raw, audioClockOriginMs)' "$mp"; then
    return 1
  fi
  if grep -q 'A/V co-arm first_frame=' "$mp"; then
    return 1
  fi
  return 0
}

if ! green_checks "$MP" "$AV" "$HPP" "$MAIN"; then
  echo "FAIL: green A/V hold-until-video wiring checks failed on tip sources" >&2
  exit 1
fi
echo "PASS green: tip sources hold + origin assert + path policy"

cp "$MP" "$WORK/media_player.cpp"
cp "$AV" "$WORK/av_clock.hpp"
cp "$HPP" "$WORK/media_player.hpp"
cp "$MAIN" "$WORK/main.cpp"

# RED TWIN A: strip content_origin_ms=0 log / gate open.
sed -i '/content_origin_ms=0/d' "$WORK/media_player.cpp"
sed -i 's/audioStartGate_.store(true, std::memory_order_release);/\/\*MUTANT no gate open*\//' \
  "$WORK/media_player.cpp"

set +e
green_checks "$WORK/media_player.cpp" "$WORK/av_clock.hpp" "$WORK/media_player.hpp" "$MAIN"
RED_A=$?
set -e
echo "av_startup_hold_red_twin_gate true rc=$RED_A"
if [[ "$RED_A" -eq 0 ]]; then
  echo "FAIL: red twin A — green_checks still passed after stripping gate/origin" >&2
  exit 1
fi
echo "PASS red twin A: green_checks fail without origin assert (rc=$RED_A)"

# RED TWIN B: re-introduce co-arm origin call.
cp "$MP" "$WORK/media_player.cpp"
if ! grep -q 'coArmedClockMs(raw, audioClockOriginMs)' "$WORK/media_player.cpp"; then
  echo '/* MUTANT */ clockMs = misterplex::coArmedClockMs(raw, audioClockOriginMs);' \
    >>"$WORK/media_player.cpp"
fi
set +e
green_checks "$WORK/media_player.cpp" "$WORK/av_clock.hpp" "$HPP" "$MAIN"
RED_B=$?
set -e
echo "av_startup_hold_red_twin_coarm true rc=$RED_B"
if [[ "$RED_B" -eq 0 ]]; then
  echo "FAIL: red twin B — green_checks still passed with co-arm reintroduced" >&2
  exit 1
fi
echo "PASS red twin B: green_checks fail when co-arm origin returns (rc=$RED_B)"

# RED TWIN C: pause touches audioStartGate_ (spurious re-arm).
cp "$MP" "$WORK/media_player.cpp"
python3 - <<'PY'
from pathlib import Path
p = Path("build/av-startup-hold-unit/media_player.cpp")
t = p.read_text()
old = "void MediaPlayer::pause() {\n    paused_.store(true);"
new = "void MediaPlayer::pause() {\n    audioStartGate_.store(false); // MUTANT re-arm on pause\n    paused_.store(true);"
if old not in t:
    raise SystemExit("pause anchor missing")
p.write_text(t.replace(old, new, 1))
PY
set +e
green_checks "$WORK/media_player.cpp" "$AV" "$HPP" "$MAIN"
RED_C=$?
set -e
echo "av_startup_hold_red_twin_pause true rc=$RED_C"
if [[ "$RED_C" -eq 0 ]]; then
  echo "FAIL: red twin C — green_checks still passed with pause re-arm mutant" >&2
  exit 1
fi
echo "PASS red twin C: green_checks fail when pause re-arms hold (rc=$RED_C)"

# Functional: tip test_avclock
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
for need in \
  'PASS startup hold-until-video' \
  'PASS release origin' \
  'PASS multisession seek/auto-next' \
  'PASS pause/resume hold policy' \
  'PASS hold no-video' \
  'startup_sim COARM'; do
  if ! printf '%s\n' "$TIP_OUT" | grep -q "$need"; then
    echo "FAIL: tip test_avclock missing: $need" >&2
    exit 1
  fi
done

echo "OK av startup hold-until-video red/green gate (paths + origin + no-video)"
