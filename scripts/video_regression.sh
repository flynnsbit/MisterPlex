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

# Accepted daemon binaries for the baseline bundle.
#
#   7cd10b4d  the pristine v0.2.0 release asset. Good video, but it also ships
#             two defects measured on hardware: the Plex Web timeline is frozen
#             at 0:00 (v0.2.0 has no pms_timeline.cpp at all) and the GDM
#             self-reply storm burns a core at idle (measured 99 %onecpu).
#   de173a59  hybrid/v0.2.0-timeline + async-signal-safe crash backtrace handler.
#             Verified by sending SIGSEGV: FATAL block written, supervisor still saw
#             rc=139, daemon respawned. Decode frames with:
#               llvm-addr2line -e <matching unstripped binary> -f -C -a 0xPC ...
#   25f6db43  hybrid + SUSPEND_MAIN_DURING_PLAY opt-in (default 0).
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   f5636ac2  hybrid + plextv: 200 without self_in_body logs no-op (not succeeded).
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   48a60809  hybrid + modern plex.tv GET api/v2/resources registration
#             (plextv_device backport). Live registration http_status=200.
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   fed70681  hybrid + reliable idle paint after stop (always DDR for idle, re-probe
#             latched kick fail, 500ms retry until land, greppable post-stop log).
#             ACCEPTED hybrid pin (live /proc/<pid>/exe as of 2026-07-30 w-armdeploy).
#   ed6af644  hybrid/v0.2.0-timeline: v0.2.0's 320x240 SPI present path plus the
#             PMS timeline reporter and the gdmIsDiscoveryProbe filter. Measured
#             on hardware: timeline advances 0 -> 8511 -> 17874 -> 26637 ms,
#             idle 1 %onecpu, edge fingerprint LEFT spread 0 / RIGHT spread 0.
#   56a53f77  REJECTED — same as de173a59 plus advertise-only
#             Protocol-Capabilities ...,provider-playback. No provider-playback
#             handlers exist; did not fix the cast picker. Reverted; do not pin.
#
# Both must produce the SAME video fingerprint, because the hybrid deliberately
# does not touch the present path. A video difference between them is a real
# regression and must fail.
BASE_DAEMON_MD5=7cd10b4d438c714a9b8c4766dc982d59
HYBRID_DAEMON_MD5=3e2cbb9881b2f54b0e4cb60238655fa7

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
  [ "$got_daemon" = "$BASE_DAEMON_MD5" ] || [ "$got_daemon" = "$HYBRID_DAEMON_MD5" ] \
    && echo "OK   daemon $got_daemon" \
    || { echo "FAIL daemon got='$got_daemon' want='$BASE_DAEMON_MD5' or '$HYBRID_DAEMON_MD5'"; rc=1; }
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
