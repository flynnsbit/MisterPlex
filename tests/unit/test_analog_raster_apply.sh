#!/usr/bin/env bash
# analogRasterApplyOnStart GREEN + RED twins (swap bits / live / mid-play / 15 kHz).
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CXX="${CXX:-g++}"
SRC="$ROOT/tests/unit/test_analog_raster_apply.cpp"
RES="$ROOT/arm/misterplexd/plex_resolve.cpp"
INC="-std=c++17 -O2 -Wall -Wextra -I$ROOT/host -I$ROOT/arm/misterplexd"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

grep -q 'analogRasterShouldApplyOnStart' "$ROOT/arm/misterplexd/main.cpp" || \
  fail "main.cpp must gate analogRasterShouldApplyOnStart on Plex_SDfamily argv"
grep -q 'applyAnalogRasterOnStart' "$ROOT/arm/misterplexd/media_player.cpp" || \
  fail "media_player must apply analog raster via setStatusBits"
grep -q 'analogRasterPokesVideoMode' "$ROOT/arm/misterplexd/media_player.cpp" || \
  fail "applyAnalogRasterOnStart must refuse video_mode / 15 kHz ascal"
fn_analog=$(awk '/void MediaPlayer::applyAnalogRasterOnStart\(/,/^void MediaPlayer::latchAndApplyDisplayRaster\(/' \
  "$ROOT/arm/misterplexd/media_player.cpp")
if printf '%s\n' "$fn_analog" | grep -q 'writeMisterCmdLine\|kMisterCmdPath\|kVideoModeCmd'; then
  fail "applyAnalogRasterOnStart must not poke /dev/MiSTer_cmd video_mode"
else
  ok "applyAnalogRasterOnStart does not write video_mode"
fi
fn_osd=$(awk '/void MediaPlayer::applyOsd\(/,/^void MediaPlayer::applyAnalogRasterOnStart\(/' \
  "$ROOT/arm/misterplexd/media_player.cpp" | sed '$d')
if printf '%s\n' "$fn_osd" | grep -vE '^[[:space:]]*//' | grep -q 'applyAnalogRasterOnStart(\|analogRasterStartPlan('; then
  fail "applyOsd must not analog-apply (live hop / mid-play)"
else
  ok "applyOsd does not analog-apply"
fi
if grep -q 'OSD_CONTROL=1' "$ROOT/scripts/misterplex_pair_conf.sh"; then
  fail "pair_conf must not ship OSD_CONTROL=1"
else
  ok "pair_conf has no OSD_CONTROL=1"
fi
grep -q 'ANALOG_RASTER=480p31' "$ROOT/scripts/misterplex_pair_conf.sh" || \
  fail "pair_conf default overlay must echo ANALOG_RASTER=480p31"
grep -q 'MISTERPLEX_LIVE_RBF=' "$ROOT/scripts/misterplex_core_watch.sh" || \
  fail "watcher must export MISTERPLEX_LIVE_RBF so analog argv gate can see Plex_SDfamily"
grep -q 'setStatusBits' "$ROOT/arm/misterplexd/media_player.cpp" || \
  fail "current-tree analog apply uses setStatusBits (gold recast is set_status CLI)"
grep -q -- '--bit 14' "$ROOT/host/libmisterplex/analog_raster.hpp" || \
  fail "analog_raster.hpp must document set_status --bit 14/--bit 15/--pulse 0"

mkdir -p "$ROOT/build"
green="$ROOT/build/test_analog_raster_apply"
if ! $CXX $INC -o "$green" "$SRC" "$RES"; then
  echo "GREEN compile failed" >&2
  exit 1
fi
set +e
"$green"
grc=$?
set -e
echo "analogRasterApplyOnStart GREEN true rc=$grc"
if [ "$grc" -ne 0 ]; then
  echo "GREEN run failed" >&2
  exit 1
fi
ok "GREEN analogRasterApplyOnStart rc=0"

run_red() {
  local def="$1" bin="$2" note="$3"
  if ! $CXX $INC -D"$def" -o "$bin" "$SRC" "$RES"; then
    fail "RED $def compile should succeed (runtime must fail)"
    return
  fi
  set +e
  "$bin" >/tmp/analog-raster-red.out 2>/tmp/analog-raster-red.err
  local rc=$?
  set -e
  echo "analogRasterApplyOnStart RED $def true rc=$rc"
  if [ "$rc" -eq 0 ]; then
    fail "RED $def twin ran rc=0 ($note)"
  else
    ok "RED $def twin true rc=$rc ($note)"
  fi
}

run_red ANALOG_RASTER_FAULT_SWAP_BITS \
  "$ROOT/build/test_analog_raster_apply_red_swap" \
  "480p31 bits != 2"
run_red ANALOG_RASTER_FAULT_LIVE_APPLY \
  "$ROOT/build/test_analog_raster_apply_red_live" \
  "applyOnOsdChange must not be true"
run_red ANALOG_RASTER_FAULT_MID_PLAY \
  "$ROOT/build/test_analog_raster_apply_red_midplay" \
  "must not fire mid-play"
run_red ANALOG_RASTER_FAULT_VIDEO_MODE \
  "$ROOT/build/test_analog_raster_apply_red_videomode" \
  "must not poke 15 kHz ascal video_mode"
run_red ANALOG_RASTER_FAULT_IGNORE_ARGV \
  "$ROOT/build/test_analog_raster_apply_red_argv" \
  "must not apply without Plex_SDfamily argv"

if [ "$fails" -ne 0 ]; then
  echo "test_analog_raster_apply.sh: $fails failure(s)" >&2
  exit 1
fi
echo "test_analog_raster_apply.sh: OK"
exit 0
