#!/usr/bin/env bash
# HDMI-LCD scoring policy. RED twin: 15 kHz cmd on LCD path must fail.
# GREEN: Display 240p → 640×480@60; 480i is CRT-only (no HDMI poke).
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDR="$ROOT/host/libmisterplex/display_raster.hpp"
SRC="$ROOT/tests/unit/test_display_raster_policy.cpp"
CXX="${CXX:-g++}"
fails=0

fail() {
  echo "FAIL: $*" >&2
  fails=$((fails + 1))
}
ok() { echo "OK: $*"; }

[ -f "$HDR" ] || { echo "missing $HDR" >&2; exit 1; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

grep -q 'kVideoModeCmd240p = "video_mode 320,16,32,48,240,4,3,15,6500"' "$HDR" \
  || fail "kVideoModeCmd240p 6500 missing"
grep -q 'kVideoModeCmd480i = "video_mode 720,19,62,57,240,4,3,15,13500"' "$HDR" \
  || fail "kVideoModeCmd480i 13500 missing"
grep -q 'kHdmiLcdMinLineHz = 31000' "$HDR" || fail "kHdmiLcdMinLineHz"
grep -q 'videoModeCmdForScoringPath' "$HDR" || fail "videoModeCmdForScoringPath missing"
if grep -nE 'videoModeCmdForScoringPath' "$HDR" | grep -q 'kVideoModeCmd240p'; then
  fail "RED: scoring path still names kVideoModeCmd240p"
else
  ok "scoring path does not emit kVideoModeCmd240p by name"
fi
grep -q 'DisplaySink::HdmiLcd' "$ROOT/arm/misterplexd/media_player.hpp" \
  || fail "daemon default sink missing"
if grep -A2 'MediaPlayer::applyDisplayRaster' "$ROOT/arm/misterplexd/media_player.cpp" \
     | grep -q 'videoModeCmdForScoringPath'; then
  ok "applyDisplayRaster uses scoring path"
else
  fail "applyDisplayRaster still uses naive label mapper"
fi

mkdir -p "$ROOT/build"
RED_SRC="$ROOT/build/test_display_raster_policy_red.cpp"
RED_BIN="$ROOT/build/test_display_raster_policy_red"
cat > "$RED_SRC" <<'EOF'
#include "libmisterplex/display_raster.hpp"
#include <cstdio>
int main() {
    using namespace misterplex;
    const char* cmd = videoModeCmdForDisplayLabel("240p");
    const char* i = videoModeCmdForDisplayLabel("480i");
    if (videoModeForbiddenOnHdmiLcd(cmd) && videoModeForbiddenOnHdmiLcd(i) &&
        cmd == kVideoModeCmd240p && i == kVideoModeCmd480i) {
        std::fprintf(stderr, "RED twin: 15 kHz cmd on LCD path (240p=%s 480i=%s)\n", cmd, i);
        return 1;
    }
    std::fprintf(stderr, "RED twin missed 15 kHz LCD landmine\n");
    return 0;
}
EOF

if ! "$CXX" -std=c++17 -Wall -Wextra -I"$ROOT/host" -o "$RED_BIN" "$RED_SRC"; then
  fail "compile RED twin"
else
  set +e
  "$RED_BIN"
  red_rc=$?
  set -e
  if [ "$red_rc" -eq 1 ]; then
    ok "RED twin: 15 kHz cmd on LCD path fails rc=$red_rc"
  else
    fail "RED twin expected rc=1 got rc=$red_rc"
  fi
fi

GREEN_BIN="$ROOT/build/test_display_raster_policy"
if ! "$CXX" -std=c++17 -Wall -Wextra -I"$ROOT/host" -o "$GREEN_BIN" "$SRC"; then
  fail "compile GREEN"
else
  set +e
  "$GREEN_BIN"
  green_rc=$?
  set -e
  if [ "$green_rc" -eq 0 ]; then
    ok "GREEN helper binary rc=$green_rc"
  else
    fail "GREEN helper binary rc=$green_rc"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "test_display_raster_policy: $fails failure(s)" >&2
  exit 1
fi
echo "test_display_raster_policy: OK"
exit 0
