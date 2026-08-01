#!/usr/bin/env bash
# Wait until misterplexd reports an advancing wall_s (session established).
# wall_s is session-relative media clock text from daemon logs — NOT frames_done,
# NOT presents, NOT unaccounted (those are void/misnamed on c5382bee).
#
# Derivation: media_player.cpp logs "wall_s=<float>" only after session origin
# is armed. We sample twice and require delta_wall > 0.
#
# Usage:
#   bash tools/avsync_wait_session.sh
#   MIN_WALL_S=5 SAMPLE_S=2 bash tools/avsync_wait_session.sh
# Exit: 0 session OK; 77 could-not-establish; 2 parse/host error
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
MIN_WALL_S="${MIN_WALL_S:-5}"
SAMPLE_S="${SAMPLE_S:-2}"
MAX_WAIT_S="${MAX_WAIT_S:-90}"
# Log paths tried on device (first hit wins per sample)
# shellcheck disable=SC2016
REMOTE_READ='
set -e
pick=""
for f in /tmp/misterplexd.log /var/log/misterplexd.log /tmp/misterplex.log \
         /media/fat/misterplex/misterplexd.log /media/fat/misterplex_v2/misterplexd.log; do
  if [ -f "$f" ]; then pick=$f; break; fi
done
if [ -z "$pick" ]; then
  # busybox logread fallback
  line=$(logread 2>/dev/null | grep "wall_s=" | tail -n 1 || true)
else
  line=$(grep "wall_s=" "$pick" 2>/dev/null | tail -n 1 || true)
fi
echo "log_src=${pick:-logread}"
echo "line=${line}"
# Extract last wall_s= number on the line (may also have frames_done_wall_s=)
echo "$line" | sed -n "s/.*[^_]wall_s=\([0-9.][0-9.]*\).*/wall_s=\1/p" | tail -n 1
'

sample_wall() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "${USER}@${HOST}" "sh -s" <<<"$REMOTE_READ" 2>/dev/null || true
}

parse_wall() {
  # stdin → print wall float or empty
  sed -n 's/^wall_s=\([0-9.][0-9.]*\)$/\1/p' | tail -n 1
}

echo "=== avsync_wait_session ==="
echo "host=$HOST min_wall_s=$MIN_WALL_S sample_s=$SAMPLE_S max_wait_s=$MAX_WAIT_S src=caller_supplied"
echo "field=wall_s derivation=session_relative_media_clock_after_origin_armed src=caller_supplied"
echo "not_used=frames_done,presents,drops,unaccounted note=void_or_misnamed_on_c5382bee"

start_mono=$(date +%s)
while true; do
  now=$(date +%s)
  elapsed=$((now - start_mono))
  if [[ "$elapsed" -ge "$MAX_WAIT_S" ]]; then
    echo "VERDICT=UNSCORED rc=77 reason=session_wall_s_not_established_within_${MAX_WAIT_S}s"
    exit 77
  fi

  s1=$(sample_wall)
  w1=$(printf '%s\n' "$s1" | parse_wall)
  echo "sample1_raw<<EOF"
  printf '%s\n' "$s1"
  echo "EOF"
  sleep "$SAMPLE_S"
  s2=$(sample_wall)
  w2=$(printf '%s\n' "$s2" | parse_wall)
  echo "sample2_raw<<EOF"
  printf '%s\n' "$s2"
  echo "EOF"

  if [[ -z "$w1" || -z "$w2" ]]; then
    echo "wall_s=NO-DATA src=measured note=retry"
    sleep 1
    continue
  fi
  # bc-free float compare via awk
  adv=$(awk -v a="$w1" -v b="$w2" 'BEGIN{
    d=b-a;
    if (d>0.05) print "yes"; else print "no";
    printf "delta=%.4f\n", d;
  }')
  delta=$(printf '%s\n' "$adv" | sed -n 's/^delta=//p')
  ok=$(printf '%s\n' "$adv" | head -n1)
  echo "wall_s_1=$w1 src=measured"
  echo "wall_s_2=$w2 src=measured"
  echo "wall_s_delta=$delta src=measured sample_s=$SAMPLE_S src=caller_supplied"
  enough=$(awk -v w="$w2" -v m="$MIN_WALL_S" 'BEGIN{print (w+0>=m+0)?"yes":"no"}')
  echo "wall_s_ge_min=$enough min_wall_s=$MIN_WALL_S src=caller_supplied"
  if [[ "$ok" == "yes" && "$enough" == "yes" ]]; then
    echo "VERDICT=SESSION_OK rc=0 wall_s=$w2 delta=$delta"
    exit 0
  fi
  echo "session_not_ready advancing=$ok wall_ge_min=$enough — retry"
  sleep 1
done
