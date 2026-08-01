#!/bin/sh
# PMS / ffmpeg HTTP arrival rate during a REAL product cast.
# Parent-only on device. Does not start/stop playback. Does not touch cores.
#
# Method: resolve product ffmpeg by readlink -f /proc/pid/exe (ERROR 14 — never
# cmdline substring). Sample /proc/pid/io rchar over ONE wall clock window.
# P = d_rchar / d_wall_s  (bytes/s). Compare to NOMINAL_BPS (default 57000 ≈ 456 kb/s).
#
# PRE-REGISTER (publish before running):
#   H1 (PMS ~1× pacing):  median ratio_vs_nominal in [0.7, 1.5] over N windows
#   FALSIFIER (not PMS-limited): median ratio >= 2.5 sustained (input >> realtime)
#   FALSIFIER (stall/other):     median ratio < 0.4 with playing session
#   NO-DATA if ffmpeg pid absent mid-window — never print 0.0 as a rate.
#
# Usage:
#   NOMINAL_BPS=57000 WINDOWS=10 WINDOW_S=1 ./pms_arrival_rate_sample.sh
#   FFMPEG_EXE_SUBSTR=ffmpeg   # matched against resolved exe path only
#
# true rc captured directly (not through a pipe on the final exit).

set -eu

NOMINAL_BPS="${NOMINAL_BPS:-57000}"
WINDOWS="${WINDOWS:-10}"
WINDOW_S="${WINDOW_S:-1}"
FFMPEG_EXE_SUBSTR="${FFMPEG_EXE_SUBSTR:-ffmpeg}"
# Optional hard pin if parent already resolved pid:
FFMPEG_PID="${FFMPEG_PID:-}"

resolve_ffmpeg_pid() {
  if [ -n "$FFMPEG_PID" ] && [ -d "/proc/$FFMPEG_PID" ]; then
    exe=$(readlink -f "/proc/$FFMPEG_PID/exe" 2>/dev/null || true)
    echo "$FFMPEG_PID $exe"
    return 0
  fi
  found=""
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null || true)
    [ -n "$exe" ] || continue
    case "$exe" in
      *"$FFMPEG_EXE_SUBSTR"*) 
        # Prefer product path shapes; still accept any resolved exe containing substr.
        found="$pid $exe"
        # Keep scanning — last match wins; parent can pin FFMPEG_PID if multiple.
        ;;
    esac
  done
  if [ -z "$found" ]; then
    echo "NO-DATA no_ffmpeg_exe_match substr=$FFMPEG_EXE_SUBSTR" >&2
    return 1
  fi
  echo "$found"
  return 0
}

read_io() {
  # prints: rchar wchar read_bytes  or fails
  pid=$1
  f="/proc/$pid/io"
  if [ ! -r "$f" ]; then
    return 1
  fi
  # busybox awk
  awk '
    /^rchar:/ { r=$2 }
    /^wchar:/ { w=$2 }
    /^read_bytes:/ { rb=$2 }
    END {
      if (r == "") exit 1
      if (w == "") w=0
      if (rb == "") rb=0
      printf "%s %s %s\n", r, w, rb
    }
  ' "$f"
}

echo "pms_arrival_rate_sample nominal_Bps=$NOMINAL_BPS windows=$WINDOWS window_s=$WINDOW_S"
echo "PRE_REGISTER H1_ratio_in=0.7..1.5 FALSIFIER_fast_ge=2.5 FALSIFIER_stall_lt=0.4"

res=$(resolve_ffmpeg_pid) || {
  echo "RESULT=NO-DATA reason=no_ffmpeg"
  echo "true rc=2"
  exit 2
}
pid=${res%% *}
exe=${res#* }
echo "ffmpeg_pid=$pid exe=$exe resolve=readlink_exe tag=measured"

i=1
ok_n=0
sum_ratio=0
fast_n=0
pace_n=0
stall_n=0

while [ "$i" -le "$WINDOWS" ]; do
  if [ ! -d "/proc/$pid" ]; then
    echo "sample=$i RESULT=NO-DATA reason=pid_gone"
    i=$((i + 1))
    continue
  fi
  # wall clock: date +%s.%N may be missing on busybox — use seconds + sleep measure
  t0=$(date +%s 2>/dev/null || echo 0)
  # prefer /proc/uptime for monotonic-ish wall
  u0=$(awk '{print $1}' /proc/uptime)
  io0=$(read_io "$pid") || {
    echo "sample=$i RESULT=NO-DATA reason=io_unreadable"
    i=$((i + 1))
    continue
  }
  sleep "$WINDOW_S"
  u1=$(awk '{print $1}' /proc/uptime)
  io1=$(read_io "$pid") || {
    echo "sample=$i RESULT=NO-DATA reason=io_unreadable_after"
    i=$((i + 1))
    continue
  }
  t1=$(date +%s 2>/dev/null || echo 0)

  dwall=$(awk -v a="$u0" -v b="$u1" 'BEGIN { d=b-a; if (d<=0) exit 1; printf "%.3f", d }') || {
    echo "sample=$i RESULT=NO-DATA reason=bad_wall"
    i=$((i + 1))
    continue
  }

  set -- $io0
  r0=$1; w0=$2; rb0=$3
  set -- $io1
  r1=$1; w1=$2; rb1=$3

  eval $(awk -v r0="$r0" -v r1="$r1" -v w0="$w0" -v w1="$w1" -v rb0="$rb0" -v rb1="$rb1" \
             -v dw="$dwall" -v nom="$NOMINAL_BPS" 'BEGIN {
    dr=r1-r0; dwc=w1-w0; drb=rb1-rb0;
    if (dw<=0) exit 1;
    bps=dr/dw;
    ratio=(nom>0)? bps/nom : -1;
    printf "drchar=%d dwchar=%d dread_bytes=%d rchar_Bps=%.1f ratio=%.3f\n",
      dr, dwc, drb, bps, ratio;
  }')

  # Classify (does not claim PASS — parent scores against PRE_REGISTER)
  class=OTHER
  awk -v r="$ratio" 'BEGIN {
    if (r >= 0.7 && r <= 1.5) exit 10;
    if (r >= 2.5) exit 11;
    if (r < 0.4 && r >= 0) exit 12;
    exit 13;
  }' && true
  rc_c=$?
  case $rc_c in
    10) class=PACE_1X; pace_n=$((pace_n + 1)) ;;
    11) class=FAST_GE_2_5X; fast_n=$((fast_n + 1)) ;;
    12) class=STALL_LT_0_4X; stall_n=$((stall_n + 1)) ;;
    *) class=OTHER ;;
  esac

  echo "sample=$i d_wall_s=$dwall d_rchar=$drchar rchar_Bps=$rchar_Bps d_wchar=$dwchar d_read_bytes=$dread_bytes nominal_Bps=$NOMINAL_BPS ratio_vs_nominal=$ratio class=$class tag=measured"
  ok_n=$((ok_n + 1))
  sum_ratio=$(awk -v s="$sum_ratio" -v r="$ratio" 'BEGIN { printf "%.6f", s+r }')
  i=$((i + 1))
done

if [ "$ok_n" -eq 0 ]; then
  echo "SUMMARY ok_n=0 RESULT=NO-DATA"
  echo "true rc=3"
  exit 3
fi

avg=$(awk -v s="$sum_ratio" -v n="$ok_n" 'BEGIN { printf "%.3f", s/n }')
echo "SUMMARY ok_n=$ok_n avg_ratio=$avg pace_1x_n=$pace_n fast_ge_2_5x_n=$fast_n stall_lt_0_4x_n=$stall_n"
echo "INTERPRET_HINT H1_supported_if_pace_1x_n_ge_half_ok_n FALSIFIED_if_fast_ge_2_5x_n_ge_half_ok_n"
echo "true rc=0"
exit 0
