#!/usr/bin/env bash
# Hold until first video + B3 timeout + B4 ring drop-head + Drop reclaim discrimination.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
echo "=== test_av_startup_hold_red EXECUTED (mutation twins; not green unit FAIL) ==="
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
  grep -q 'audio hold TIMEOUT' "$mp" || return 1
  grep -q 'kAudioHoldTimeoutMs' "$mp" || return 1
  grep -q 'kAudioHoldTimeoutMs' "$av" || return 1
  grep -q 'ring drop HEAD' "$mp" || return 1
  if grep -q 'keeping stream start, dropping tail' "$mp"; then return 1; fi
  if grep -q 'no auto-release without video' "$mp"; then return 1; fi
  # Name may appear in comments documenting removal; fail only on live use.
  if grep -nE 'suppressStartupPrefill\s*[=;(]' "$mp" >/dev/null; then return 1; fi
  grep -q 'holdRingAppendDropHead' "$av" || return 1
  grep -q 'kStartupDropWallMs' "$av" || return 1
  grep -q 'grabberOffsetMs' "$av" || return 1
  grep -q 'HoldUntilVideo' "$av" || return 1
  grep -q 'handoffReArmsAudioHold' "$av" || return 1
  grep -q 'simulateMultiSessionStartup' "$av" || return 1
  grep -q 'simulatePauseResumeHold' "$av" || return 1
  grep -q 'simulateHoldNoVideo' "$av" || return 1
  # Peer-aligned hold drain + first-class held_ms
  grep -q 'holdDrainShouldPastBias' "$av" || return 1
  grep -q 'holdDrainBurstLeadMs' "$av" || return 1
  grep -q 'makeHoldSessionReport' "$av" || return 1
  grep -q 'peerBothReadyArm' "$av" || return 1
  grep -q 'ENGINEERING COMPROMISE' "$mp" || return 1
  grep -q 'hold_drain_no_past_bias' "$mp" || return 1
  grep -q 'lastHeldMs_' "$hpp" || return 1
  grep -q 'holdDrainShouldPastBias' "$mp" || return 1
  grep -q 'play(withUniversalOffset' "$mp" || return 1
  grep -q 'tryAutoNext' "$main" || return 1
  grep -q 'doPlay' "$main" || return 1
  if grep -n 'void MediaPlayer::pause' -A20 "$mp" | grep -q 'audioStartGate_'; then return 1; fi
  if grep -n 'void MediaPlayer::resume' -A20 "$mp" | grep -q 'audioStartGate_'; then return 1; fi
  if grep -q 'coArmedClockMs(raw, audioClockOriginMs)' "$mp"; then return 1; fi
  if grep -q 'A/V co-arm first_frame=' "$mp"; then return 1; fi
  return 0
}

if ! green_checks "$MP" "$AV" "$HPP" "$MAIN"; then
  echo "FAIL: green checks failed" >&2; exit 1
fi
echo "PASS green"

cp "$MP" "$WORK/media_player.cpp"; cp "$AV" "$WORK/av_clock.hpp"
cp "$HPP" "$WORK/media_player.hpp"; cp "$MAIN" "$WORK/main.cpp"
sed -i '/content_origin_ms=0/d' "$WORK/media_player.cpp"
sed -i 's/audioStartGate_.store(true, std::memory_order_release);/\/\*MUTANT*\//' "$WORK/media_player.cpp"
set +e; green_checks "$WORK/media_player.cpp" "$WORK/av_clock.hpp" "$HPP" "$MAIN"; RED_A=$?; set -e
echo "twin_gate rc=$RED_A"; [[ "$RED_A" -ne 0 ]]

cp "$MP" "$WORK/media_player.cpp"
echo '/* MUTANT */ clockMs = misterplex::coArmedClockMs(raw, audioClockOriginMs);' >>"$WORK/media_player.cpp"
set +e; green_checks "$WORK/media_player.cpp" "$AV" "$HPP" "$MAIN"; RED_B=$?; set -e
echo "twin_coarm rc=$RED_B"; [[ "$RED_B" -ne 0 ]]

cp "$MP" "$WORK/media_player.cpp"
python3 - <<'PY'
from pathlib import Path
p=Path("build/av-startup-hold-unit/media_player.cpp"); t=p.read_text()
old="void MediaPlayer::pause() {\n    paused_.store(true);"
new="void MediaPlayer::pause() {\n    audioStartGate_.store(false);\n    paused_.store(true);"
assert old in t; p.write_text(t.replace(old,new,1))
PY
set +e; green_checks "$WORK/media_player.cpp" "$AV" "$HPP" "$MAIN"; RED_C=$?; set -e
echo "twin_pause rc=$RED_C"; [[ "$RED_C" -ne 0 ]]

cp "$MP" "$WORK/media_player.cpp"
python3 - <<'PY'
from pathlib import Path
p=Path("build/av-startup-hold-unit/media_player.cpp"); t=p.read_text()
t=t.replace("ring drop HEAD keep live tail (no content jump on release)","keeping stream start, dropping tail until release")
t=t.replace("audio hold TIMEOUT","audio hold NO_TIMEOUT_MUTANT"); p.write_text(t)
PY
set +e; green_checks "$WORK/media_player.cpp" "$AV" "$HPP" "$MAIN"; RED_D=$?; set -e
echo "twin_policy rc=$RED_D"; [[ "$RED_D" -ne 0 ]]

CXX_BIN="${CXX:-g++}"; CXX_FLAGS=(-std=c++17 -O2 -Wall -Wextra)
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$ROOT/host" -o "$WORK/test_avclock_tip" "$ROOT/tests/unit/test_avclock.cpp"
set +e; TIP_OUT="$("$WORK/test_avclock_tip" 2>&1)"; TIP_RC=$?; set -e
printf '%s\n' "$TIP_OUT"; echo "tip rc=$TIP_RC"; [[ "$TIP_RC" -eq 0 ]]
for need in \
  'PASS startup drop variance' \
  'PASS hold no-video' \
  'PASS peer hold drain' \
  'PRE_REGISTER HOLD_IDEAL predicted_startup_drops' \
  'PRE_REGISTER residual_lead_ms for drops=12' \
  'PRE_REGISTER PEER_DRAIN' \
  'SIGN_CONVENTION grabber_offset_ms' \
  'CRITERION lip_sync=tools/avsync_measure_hdmi.py ONLY' \
  'H_DROP_STATUS REJECTED' \
  'MISS_PUBLISHED H-DROP' \
  'PEER_HOLD NOT-FOUND' \
  'PEER_HOLD CITED'; do
  printf '%s\n' "$TIP_OUT" | grep -q "$need" || { echo "missing $need" >&2; exit 1; }
done
# PRIMARY discrimination: exact silicon soak drop counts (12 and 15).
DROPS12=$(printf '%s\n' "$TIP_OUT" | sed -n 's/.*drops12=\([0-9][0-9]*\).*/\1/p' | head -1)
DROPS15=$(printf '%s\n' "$TIP_OUT" | sed -n 's/.*drops15=\([0-9][0-9]*\).*/\1/p' | head -1)
HOLD_DROPS=$(printf '%s\n' "$TIP_OUT" | sed -n 's/.*hold_ideal_drops=\([0-9][0-9]*\).*/\1/p' | head -1)
DLEAD=$(printf '%s\n' "$TIP_OUT" | sed -n 's/.*dLead=\([0-9][0-9]*\).*/\1/p' | head -1)
[[ "$DROPS12" == "12" && "$DROPS15" == "15" ]]
[[ -n "$HOLD_DROPS" && "$HOLD_DROPS" -le 2 ]]
[[ -n "$DLEAD" && "$DLEAD" -ge 100 && "$DLEAD" -le 140 ]]
echo "PASS discrimination drops12=$DROPS12 drops15=$DROPS15 hold_ideal_drops=$HOLD_DROPS dLead=$DLEAD"

# Mutant: Drop wall ≈ content period ⇒ reclaim≈0 ⇒ cannot hit exact 12/15 map.
mkdir -p "$WORK/inc/libmisterplex"
sed 's/kStartupDropWallMs = 0/kStartupDropWallMs = 41/' "$AV" >"$WORK/inc/libmisterplex/av_clock.hpp"
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$WORK/inc" -I"$ROOT/host" -o "$WORK/test_avclock_zero" "$ROOT/tests/unit/test_avclock.cpp"
set +e; ZOUT="$("$WORK/test_avclock_zero" 2>&1)"; ZRC=$?; set -e
printf '%s\n' "$ZOUT" | tail -20
echo "bad_drop_wall rc=$ZRC"; [[ "$ZRC" -ne 0 ]]

# Mutant: holdDrainShouldPastBias always true (old past-bias-on-drain) ⇒ peer test RED.
sed 's/return !holdBufNonEmpty;/return true; \/* MUTANT past-bias always *\//' "$AV" \
  >"$WORK/inc/libmisterplex/av_clock.hpp"
"$CXX_BIN" "${CXX_FLAGS[@]}" -I"$WORK/inc" -I"$ROOT/host" -o "$WORK/test_avclock_bias" \
  "$ROOT/tests/unit/test_avclock.cpp"
set +e; BOUT="$("$WORK/test_avclock_bias" 2>&1)"; BRC=$?; set -e
printf '%s\n' "$BOUT" | tail -15
echo "bad_past_bias rc=$BRC"; [[ "$BRC" -ne 0 ]]
echo "OK hold B3/B4 + peer-drain red/green"
