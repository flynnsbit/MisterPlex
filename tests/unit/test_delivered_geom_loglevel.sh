#!/usr/bin/env bash
# B2: product rawvideo ffmpeg must use -loglevel info (not error) so Stream
# banners yield delivered_geom; MEASURED_DELIVERY must name src=ffmpeg_banner.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MP="$ROOT/arm/misterplexd/media_player.cpp"
FAIL=0

# Product play path: the block that sets -stats then -loglevel must be "info".
# Demux/audio-only/probe may stay error — they are not delivery geometry.
block=$(awk '
  /args\.push_back\("-stats"\)/ { on=1 }
  on { print }
  on && /args\.push_back\("-nostdin"\)/ { exit }
' "$MP")
echo "$block" | grep -q 'push_back("-loglevel")' || { echo "FAIL: no loglevel after -stats" >&2; FAIL=1; }
echo "$block" | grep -q 'push_back("info")' || { echo "FAIL: product path loglevel != info" >&2; FAIL=1; }
if echo "$block" | grep -q 'push_back("error")'; then
  echo "FAIL: product rawvideo path still has -loglevel error (suppresses Stream banner)" >&2
  FAIL=1
fi

grep -q 'delivered_geom=' "$MP" || { echo "FAIL: missing delivered_geom= field" >&2; FAIL=1; }
grep -q 'src=ffmpeg_banner' "$MP" || { echo "FAIL: missing src=ffmpeg_banner derivation" >&2; FAIL=1; }
# Pump must not log every info line — only geometry (flood guard).
grep -q 'parseFfmpegGeometryLine' "$MP" || { echo "FAIL: no geometry parse" >&2; FAIL=1; }

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL test_delivered_geom_loglevel" >&2
  exit 1
fi
echo "OK test_delivered_geom_loglevel (loglevel=info + delivered_geom src=ffmpeg_banner)"
exit 0
