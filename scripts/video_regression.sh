#!/usr/bin/env bash
# video_regression.sh — compare a candidate build against the known-good v0.2.0
# baseline on real hardware, using HDMI-over-USB capture.
#
# WHY: the v0.2.0 GitHub release is the last combination proven on hardware to
# render playback without the left-edge defect. Any new core/daemon must be
# measured against it, not against a previous broken build.
#
# BASELINE (do not change without new hardware evidence + updating these hashes):
#   core   /media/fat/_Utility/Plex_v2.rbf              dfebf2bfd08dd70b473b587dd7e81848
#   daemon /media/fat/misterplex_v2/bin/misterplexd     7cd10b4d438c714a9b8c4766dc982d59
#   PRESENT=fpga   (fb0 decodes but never reaches HDMI: pfps stays 0.00)
#
# THIS SCRIPT IS FOR THE PARENT ORCHESTRATOR ONLY. Agents must not run it —
# they have no device access. See AGENTS.md "Who tests".
#
# Usage:
#   scripts/video_regression.sh baseline    # measure the v0.2.0 reference
#   scripts/video_regression.sh dev         # measure the development build
#   scripts/video_regression.sh verify      # just check baseline hashes

set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
VIDEO="${VIDEO_DEV:-/dev/video0}"
OUT="${OUT_DIR:-/tmp/vidreg}"
FRAMES="${FRAMES:-45}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BASE_CORE_MD5=dfebf2bfd08dd70b473b587dd7e81848
BASE_DAEMON_MD5=7cd10b4d438c714a9b8c4766dc982d59

# Test clip: the 240p burned-in-telemetry ladder entry. Its overlay text makes
# left-edge clipping obvious to the eye as well as to the measurement.
PMS_ID="${PMS_ID:-bf36a3ad8d4f6810ab3f69ec9f1adb22a7a9dc8a}"
PMS_HOST="${PMS_HOST:-192.168.1.24}"
RATING_KEY="${RATING_KEY:-3}"
TOKEN_FILE="${TOKEN_FILE:-/tmp/.tok}"

sshm() { sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "root@$HOST" "$@"; }

verify_baseline() {
  echo "== verifying baseline hashes on device =="
  local got_core got_daemon rc=0
  got_core=$(sshm "md5sum /media/fat/_Utility/Plex_v2.rbf 2>/dev/null | cut -d' ' -f1" || true)
  got_daemon=$(sshm "md5sum /media/fat/misterplex_v2/bin/misterplexd 2>/dev/null | cut -d' ' -f1" || true)
  [ "$got_core" = "$BASE_CORE_MD5" ] \
    && echo "OK   core   $got_core" \
    || { echo "FAIL core   got='$got_core' want='$BASE_CORE_MD5'"; rc=1; }
  [ "$got_daemon" = "$BASE_DAEMON_MD5" ] \
    && echo "OK   daemon $got_daemon" \
    || { echo "FAIL daemon got='$got_daemon' want='$BASE_DAEMON_MD5'"; rc=1; }
  return $rc
}

run_bundle() {
  local which="$1" core conf_root
  case "$which" in
    baseline) core=/media/fat/_Utility/Plex_v2.rbf; conf_root=/media/fat/misterplex_v2 ;;
    dev)      core=/media/fat/_Utility/Plex.rbf;    conf_root=/media/fat/misterplex ;;
    *) echo "unknown bundle: $which"; exit 1 ;;
  esac

  # plexctl holds an exclusive flock, so exactly one daemon can ever run.
  # Duplicate daemons were observed competing as frame writers.
  echo "== starting $which bundle (single-instance enforced) =="
  sshm "/media/fat/misterplex/bin/plexctl.sh $(
        [ "$which" = baseline ] && echo v2 || echo dev)" | head -3

  echo "== loading core $core =="
  sshm "printf '%s\n' 'load_core $core' > /dev/MiSTer_cmd"
  sleep 14

  local n
  n=$(sshm "pidof misterplexd | wc -w")
  [ "$n" -eq 1 ] || { echo "FAIL expected exactly 1 daemon, got $n"; exit 3; }
  echo "daemon count OK: $n"

  echo "== casting ratingKey=$RATING_KEY =="
  local tok; tok=$(cat "$TOKEN_FILE")
  curl -s -m 25 "http://$HOST:3005/player/playback/playMedia\
?address=$PMS_HOST&port=32400&protocol=http\
&key=%2Flibrary%2Fmetadata%2F$RATING_KEY&machineIdentifier=$PMS_ID\
&offset=0&commandID=1&X-Plex-Token=$tok" >/dev/null
  sleep 22

  echo "== telemetry =="
  sshm "tail -3 $conf_root/misterplexd.log"

  echo "== capturing $FRAMES frames =="
  mkdir -p "$OUT/$which"; rm -f "$OUT/$which"/*.png
  ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
         -i "$VIDEO" -frames:v "$FRAMES" -y "$OUT/$which/f_%02d.png"

  echo "== measuring =="
  python3 "$REPO/tools/measure_edges.py" "$OUT/$which"/*.png
}

case "${1:-verify}" in
  verify)   verify_baseline ;;
  baseline) verify_baseline; run_bundle baseline ;;
  dev)      run_bundle dev ;;
  *) echo "usage: $0 {baseline|dev|verify}"; exit 1 ;;
esac
