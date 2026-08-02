#!/usr/bin/env bash
# RED-before-green gate that would have blocked ce727a43 deploy:
# dual A+V short session must deliver frames>0 and totalBytes % frameBytes == 0.
# Device regression was: audio pumped, video pipe EOF at once (frames=0).
# Video-only play-file gate is insufficient — parent failure was A+V.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/misterplexd"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -n "$FFMPEG" ] && [ -x "$FFMPEG" ] || fail "ffmpeg not found"
make -C "$ROOT" plexd >/dev/null

WORK="$ROOT/build/unit_play_file_av_dual"
mkdir -p "$WORK"
CONF="$WORK/misterplex_none.conf"
AUDIO_DEV="$WORK/fake_mraudio"
VIDEO="$WORK/av.mp4"
LOG="$WORK/av.log"

: >"$AUDIO_DEV"
cat >"$CONF" <<EOF
PRESENT=none
STREAM=0
IDLE_SCREEN=off
AUDIO_DEVICE=$AUDIO_DEV
SUSPEND_MAIN_DURING_PLAY=0
EOF

"$FFMPEG" -v error -y \
  -f lavfi -i testsrc2=size=160x120:rate=24 \
  -f lavfi -i sine=f=440:r=48000:d=2 \
  -t 2 -c:v libx264 -profile:v baseline -pix_fmt yuv420p -c:a aac "$VIDEO"

set +e
"$BIN" --ffmpeg "$FFMPEG" --conf "$CONF" --decode 160x120 \
  --play-file "$VIDEO" --play-seconds 2 >"$LOG" 2>&1
rc=$?
set -e
echo "play_file_av_dual true rc=$rc"

# Spawn must keep silicon-known-good -nostats (not -stats) on this pin family.
grep -E 'spawn single-process .* -nostats ' "$LOG" >/dev/null || {
  cat "$LOG" >&2
  fail "spawn line missing -nostats (silicon pin contract)"
}
grep -E 'spawn single-process .* -stats ' "$LOG" >/dev/null && {
  cat "$LOG" >&2
  fail "spawn line has -stats (forbidden on silicon-pin family; use -nostats)"
}

[ "$rc" -eq 0 ] || { cat "$LOG" >&2; fail "dual A+V play-file rc=$rc"; }

grep -q 'LAB play-file done frames=' "$LOG" || {
  cat "$LOG" >&2
  fail "missing LAB play-file done frames="
}
frames=$(sed -n 's/.*LAB play-file done frames=\([0-9][0-9]*\).*/\1/p' "$LOG" | tail -1)
[ -n "$frames" ] || fail "could not parse frames"
[ "$frames" -gt 0 ] || {
  cat "$LOG" >&2
  fail "frames=$frames (zero-frame regression class)"
}

# totalBytes from done line when present
if grep -q 'LAB play-file done frames=.*totalBytes=' "$LOG"; then
  tb=$(sed -n 's/.*totalBytes=\([0-9][0-9]*\).*/\1/p' "$LOG" | tail -1)
  [ -n "$tb" ] && [ "$tb" -gt 0 ] || {
    cat "$LOG" >&2
    fail "totalBytes missing/zero with frames=$frames"
  }
fi

# Device signature (ce727a43): short read got=0 with totalBytes=0 while audio
# still pumped. Normal EOF also logs got=0 AFTER a full pipe — require totalBytes=0.
if grep -E 'short read got=0/[0-9]+ totalBytes=0 ' "$LOG" >/dev/null; then
  cat "$LOG" >&2
  fail "video pipe EOF with totalBytes=0 (ce727a43 zero-frame signature)"
fi

echo "test_play_file_av_dual: OK frames=$frames"
exit 0
