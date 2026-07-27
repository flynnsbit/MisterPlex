#!/usr/bin/env bash
# Guard lab --play-file delivery: video-only sources must not be killed by an
# empty optional audio output, and zero decoded frames must fail loudly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/misterplexd"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -n "$FFMPEG" ] && [ -x "$FFMPEG" ] || fail "ffmpeg not found"
make -C "$ROOT" plexd >/dev/null

WORK="$ROOT/build/unit_play_file_delivery"
mkdir -p "$WORK"
CONF="$WORK/misterplex_none.conf"
AUDIO_DEV="$WORK/fake_mraudio"
VIDEO="$WORK/video_only.mp4"
EMPTY="$WORK/empty.mp4"
GOOD_LOG="$WORK/good.log"
BAD_LOG="$WORK/bad.log"

: >"$AUDIO_DEV"
cat >"$CONF" <<EOF_CONF
PRESENT=none
STREAM=0
IDLE_SCREEN=off
AUDIO_DEVICE=$AUDIO_DEV
EOF_CONF

"$FFMPEG" -v error -y \
  -f lavfi -i testsrc2=size=160x120:rate=4 \
  -t 1 -an -c:v libx264 -profile:v baseline -pix_fmt yuv420p "$VIDEO"

"$BIN" --ffmpeg "$FFMPEG" --conf "$CONF" --decode 160x120 \
  --play-file "$VIDEO" --play-seconds 1 >"$GOOD_LOG" 2>&1 || {
    cat "$GOOD_LOG" >&2
    fail "video-only play-file should deliver frames"
  }
grep -q "audio disabled for session: no audio stream detected" "$GOOD_LOG" || {
  cat "$GOOD_LOG" >&2
  fail "video-only source did not log audio-disable guard"
}
grep -q "LAB play-file done frames=" "$GOOD_LOG" || {
  cat "$GOOD_LOG" >&2
  fail "successful play-file did not report delivered frame count"
}
if grep -q "zero frames delivered" "$GOOD_LOG"; then
  cat "$GOOD_LOG" >&2
  fail "successful play-file reported zero frames"
fi

: >"$EMPTY"
set +e
"$BIN" --ffmpeg "$FFMPEG" --conf "$CONF" --decode 160x120 \
  --play-file "$EMPTY" --play-seconds 1 >"$BAD_LOG" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || {
  cat "$BAD_LOG" >&2
  fail "empty play-file returned success"
}
grep -q "zero frames delivered" "$BAD_LOG" || {
  cat "$BAD_LOG" >&2
  fail "empty play-file did not fail loudly as zero frames delivered"
}
grep -Eq "short_read=1|got=0/" "$BAD_LOG" || {
  cat "$BAD_LOG" >&2
  fail "zero-frame diagnostic did not include short-read details"
}

echo "test_play_file_delivery: OK"
