#!/usr/bin/env bash
# L58 farm HDMI grab on node-worker1. First still is false-black (md5 e74e3559);
# discard f0, keep f1/f2. Parent calls this during play. USB ≠ CRT.
# Usage: PATH=/tmp/misterplex-sshbin:$PATH scripts/hdmi_grab_farm.sh [TAG]
# Always exits 0; parent reads the JPEGs.
set -u

TAG="${1:-play}"
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || TAG=play
HOST=node-worker1
DIR=/tmp/misterplex-eyes
FF="ffmpeg -y -hide_banner -loglevel error -f v4l2 -input_format mjpeg -video_size 1280x720 -i /dev/video0 -frames:v 1"

mkdir -p "$DIR"

ssh "$HOST" "mkdir -p '$DIR' && \
  $FF '$DIR/${TAG}-f0.jpg'; sleep 1; \
  $FF '$DIR/${TAG}-f1.jpg'; sleep 0.4; \
  $FF '$DIR/${TAG}-f2.jpg'" || true

scp -q "$HOST:$DIR/${TAG}-f1.jpg" "$DIR/${TAG}-f1.jpg" || true
scp -q "$HOST:$DIR/${TAG}-f2.jpg" "$DIR/${TAG}-f2.jpg" || true

echo "TAG=$TAG HOST=$HOST"
for n in f1 f2; do
  f="$DIR/${TAG}-${n}.jpg"
  if [ -f "$f" ]; then
    sz=$(wc -c <"$f" | tr -d ' ')
    md=$(md5sum "$f" | awk '{print $1}')
    note=
    case "$md" in e74e3559*) note=" FALSE-BLACK" ;; esac
    printf '%s bytes=%s md5=%s%s\n' "$f" "$sz" "$md" "$note"
  else
    printf '%s MISSING\n' "$f"
  fi
done

exit 0
