#!/bin/sh
# PMS socket Recv-Q backlog during a REAL product cast (ON DEVICE).
# Parent-only. Read-only. Does not start/stop playback or touch cores.
#
# =============================================================================
# VOID — do NOT use /proc/<pid>/io rchar for PMS supply (parent 2026-08-01):
#   Live ffmpeg: rchar=1037 syscr=5 wchar=414MB while vfps≈24 healthy.
#   HTTP input is recv(); rchar does not count it on this kernel.
#   Old tools/pms_arrival_rate_sample.sh scored rchar→STALL 12/12 = blind RED.
#   NOMINAL_BPS ratio = ERROR 17 (assumed constant). Both deleted from scoring.
# =============================================================================
#
# Method:
#   1) Resolve ffmpeg by readlink -f /proc/<pid>/exe (ERROR 14 — never cmdline).
#   2) Find PMS TCP socket: /proc/<pid>/fd/* → socket:[inode], match ss -tinp
#      on pid= AND fd= (prefer peer :32400 if present).
#   3) Score Recv-Q backlog — no assumed nominal bitrate.
#        recv_q >= BACKLOG_MIN (default 100000) → BACKLOG_HELD → not supply-limited
#        recv_q == 0 → QUEUE_EMPTY (NOT a defect class)
#   4) MANDATORY liveness: daemon wall_s must advance by >= LIVE_MIN_S over each
#      window (from misterplexd log). Dead session → NO-DATA window, never 0.0.
#   5) Blindness self-check: if every scored recv_q were unusable while wchar
#      advances, exit 77 NO-DATA — never emit a defect verdict from a blind counter.
#
# PRE-REGISTER (fill before run):
#   PREDICT_verdict=NOT_SUPPLY_LIMITED   # parent already measured held ~0.5MB
#   FALSIFIER: majority QUEUE_EMPTY with bytes_received flat while wall_s advances
#              does NOT prove supply-limit; only INCONCLUSIVE without backlog.
#
# Usage (on device, during state=playing):
#   WINDOWS=10 WINDOW_S=2 BACKLOG_MIN=100000 sh tools/pms_recvq_backlog_sample.sh
#   echo "true rc=$?"    # capture directly — never through a pipe
#
# rc: 0 scored; 77 NO-DATA/unscored; 2 setup fail

set -eu

WINDOWS="${WINDOWS:-10}"
WINDOW_S="${WINDOW_S:-2}"
BACKLOG_MIN="${BACKLOG_MIN:-100000}"
LIVE_MIN_S="${LIVE_MIN_S:-}"  # default: half of WINDOW_S
FFMPEG_EXE_SUBSTR="${FFMPEG_EXE_SUBSTR:-ffmpeg}"
FFMPEG_PID="${FFMPEG_PID:-}"
SS_BIN="${SS_BIN:-/usr/sbin/ss}"
[ -x "$SS_BIN" ] || SS_BIN="$(command -v ss 2>/dev/null || true)"
LOG_HINT="${LOG_HINT:-}"  # optional explicit misterplexd log path

if [ -z "$LIVE_MIN_S" ]; then
  LIVE_MIN_S=$(awk -v w="$WINDOW_S" 'BEGIN { printf "%.3f", w * 0.5 }')
fi

echo "pms_recvq_backlog_sample windows=$WINDOWS window_s=$WINDOW_S backlog_min=$BACKLOG_MIN live_min_s=$LIVE_MIN_S"
echo "VOID_rchar=1 note=recv_not_in_rchar_on_this_kernel VOID_nominal_bps=1"
echo "PRE_REGISTER predict_verdict=NOT_SUPPLY_LIMITED falsifier=not_majority_BACKLOG_HELD_with_live_session"

if [ -z "$SS_BIN" ] || [ ! -x "$SS_BIN" ]; then
  echo "RESULT=NO-DATA reason=ss_missing"
  echo "true rc=77"
  exit 77
fi

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
      *"$FFMPEG_EXE_SUBSTR"*) found="$pid $exe" ;;
    esac
  done
  if [ -z "$found" ]; then
    echo "NO-DATA no_ffmpeg_exe_match" >&2
    return 1
  fi
  echo "$found"
}

# Last wall_s= from daemon log (session clock). NO-DATA if missing.
read_wall_s() {
  pick="$LOG_HINT"
  if [ -z "$pick" ] || [ ! -f "$pick" ]; then
    pick=""
    for f in /tmp/misterplexd.log /var/log/misterplexd.log \
             /media/fat/misterplex/misterplexd.log \
             /media/fat/misterplex_v2/misterplexd.log; do
      if [ -f "$f" ]; then pick=$f; break; fi
    done
  fi
  line=""
  if [ -n "$pick" ]; then
    line=$(grep "wall_s=" "$pick" 2>/dev/null | tail -n 1 || true)
  else
    line=$(logread 2>/dev/null | grep "wall_s=" | tail -n 1 || true)
  fi
  # Prefer bare wall_s= not frames_done_wall_s=
  echo "$line" | sed -n 's/.*[^a-z_]wall_s=\([0-9.][0-9.]*\).*/\1/p' | tail -n 1
}

read_wchar() {
  pid=$1
  f="/proc/$pid/io"
  [ -r "$f" ] || { echo ""; return 1; }
  awk '/^wchar:/ { print $2; exit }' "$f"
}

# Discover socket fds; prefer ss match with :32400 peer (PMS).
find_pms_fd() {
  pid=$1
  best_fd=""
  best_rq=-1
  for link in /proc/$pid/fd/*; do
    [ -e "$link" ] || continue
    tgt=$(readlink "$link" 2>/dev/null || true)
    case "$tgt" in
      socket:\[*\]) ;;
      *) continue ;;
    esac
    fd=${link##*/}
    # ss line for this pid+fd
    blob=$("$SS_BIN" -tinp 2>/dev/null | grep -E "pid=$pid,fd=$fd|pid=$pid," || true)
    echo "$blob" | grep -q "pid=$pid" || continue
    # Prefer PMS port
    pms=0
    echo "$blob" | grep -q ":32400" && pms=1
    rq=$(echo "$blob" | awk '
      /Recv-Q[ :]/ {
        for (i=1;i<=NF;i++) if ($i ~ /^Recv-Q/) { print $(i+1); exit }
      }
      $1 ~ /^(ESTAB|ESTABLISHED|FIN-WAIT|CLOSE-WAIT|SYN-)/ {
        if ($2 ~ /^[0-9]+$/) { print $2; exit }
      }
    ' | head -n 1)
    [ -n "$rq" ] || rq=-1
    if [ "$pms" -eq 1 ]; then
      echo "$fd"
      return 0
    fi
    # track max recv-q as fallback
    if [ "$rq" -ge 0 ] 2>/dev/null; then
      if [ -z "$best_fd" ] || [ "$rq" -gt "$best_rq" ]; then
        best_fd=$fd
        best_rq=$rq
      fi
    elif [ -z "$best_fd" ]; then
      best_fd=$fd
    fi
  done
  if [ -n "$best_fd" ]; then
    echo "$best_fd"
    return 0
  fi
  return 1
}

read_recvq_bytes() {
  pid=$1
  fd=$2
  blob=$("$SS_BIN" -tinp 2>/dev/null || true)
  # Narrow to pid+fd
  chunk=$(echo "$blob" | awk -v p="$pid" -v f="$fd" '
    BEGIN { take=0; buf="" }
    {
      if ($0 ~ ("pid=" p) && $0 ~ ("fd=" f)) { take=1; buf=$0; next }
      if (take==1) {
        if ($0 ~ /^[A-Z]/ || $0 ~ /^tcp/ || $0 ~ /^u_str/) {
          # next record
          print buf
          take=0; buf=""
          if ($0 ~ ("pid=" p) && $0 ~ ("fd=" f)) { take=1; buf=$0 }
        } else {
          buf=buf "\n" $0
        }
      }
    }
    END { if (take) print buf }
  ')
  if [ -z "$chunk" ]; then
    # looser: any line with pid= and fd=
    chunk=$(echo "$blob" | grep "pid=$pid" | grep "fd=$fd" || true)
  fi
  if [ -z "$chunk" ]; then
    return 1
  fi
  rq=$(echo "$chunk" | awk '
    /Recv-Q[ :]/ {
      for (i=1;i<=NF;i++) if ($i ~ /^Recv-Q/) { print $(i+1); exit }
    }
    $1 ~ /^(ESTAB|ESTABLISHED)/ && $2 ~ /^[0-9]+$/ { print $2; exit }
  ' | head -n 1)
  br=$(echo "$chunk" | sed -n 's/.*bytes_received:\([0-9][0-9]*\).*/\1/p' | head -n 1)
  [ -n "$rq" ] || return 1
  [ -n "$br" ] || br="NO-DATA"
  echo "$rq $br"
}

res=$(resolve_ffmpeg_pid) || {
  echo "RESULT=NO-DATA reason=no_ffmpeg"
  echo "true rc=77"
  exit 77
}
pid=${res%% *}
exe=${res#* }
echo "ffmpeg_pid=$pid exe=$exe resolve=readlink_exe tag=measured"

fd=$(find_pms_fd "$pid") || {
  echo "RESULT=NO-DATA reason=no_socket_fd"
  echo "true rc=77"
  exit 77
}
echo "socket_fd=$fd tag=measured"

wchar0=$(read_wchar "$pid" || echo "")
echo "wchar0=${wchar0:-NO-DATA} note=work_counter_not_scored_for_supply tag=measured"

i=1
ok_n=0
held_n=0
low_n=0
empty_n=0
nodata_n=0
min_rq=""
max_rq=""
# track if any sample had recv_q parsed
scored_any_nonzero=0

while [ "$i" -le "$WINDOWS" ]; do
  if [ ! -d "/proc/$pid" ]; then
    echo "sample=$i RESULT=NO-DATA reason=pid_gone live=NO"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  fi

  w0=$(read_wall_s || true)
  u0=$(awk '{print $1}' /proc/uptime)
  rb0=$(read_recvq_bytes "$pid" "$fd" || true)

  sleep "$WINDOW_S"

  w1=$(read_wall_s || true)
  u1=$(awk '{print $1}' /proc/uptime)
  rb1=$(read_recvq_bytes "$pid" "$fd" || true)

  dwall=$(awk -v a="$u0" -v b="$u1" 'BEGIN { d=b-a; if (d<=0) exit 1; printf "%.3f", d }') || {
    echo "sample=$i RESULT=NO-DATA reason=bad_uptime_wall"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  }

  # Liveness gate: daemon wall_s must advance
  live=NO
  if [ -n "$w0" ] && [ -n "$w1" ]; then
    live=$(awk -v a="$w0" -v b="$w1" -v m="$LIVE_MIN_S" 'BEGIN {
      d=b-a; if (d>=m) print "YES"; else print "NO";
    }')
    dw_sess=$(awk -v a="$w0" -v b="$w1" 'BEGIN { printf "%.3f", b-a }')
  else
    dw_sess=NO-DATA
  fi

  if [ "$live" != "YES" ]; then
    echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=NO RESULT=NO-DATA reason=session_wall_s_not_advancing wall0=${w0:-NO-DATA} wall1=${w1:-NO-DATA}"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  fi

  if [ -z "$rb1" ]; then
    echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=YES RESULT=NO-DATA reason=ss_parse_fail"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  fi

  set -- $rb1
  rq=$1
  br=$2

  class=NO-DATA
  if [ "$rq" -eq 0 ] 2>/dev/null; then
    class=QUEUE_EMPTY
    empty_n=$((empty_n + 1))
  elif [ "$rq" -ge "$BACKLOG_MIN" ] 2>/dev/null; then
    class=BACKLOG_HELD
    held_n=$((held_n + 1))
    scored_any_nonzero=1
  elif [ "$rq" -gt 0 ] 2>/dev/null; then
    class=BACKLOG_LOW
    low_n=$((low_n + 1))
    scored_any_nonzero=1
  else
    class=NO-DATA
    nodata_n=$((nodata_n + 1))
    echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=YES recv_q=NO-DATA class=NO-DATA"
    i=$((i + 1))
    continue
  fi

  ok_n=$((ok_n + 1))
  if [ -z "$min_rq" ] || [ "$rq" -lt "$min_rq" ]; then min_rq=$rq; fi
  if [ -z "$max_rq" ] || [ "$rq" -gt "$max_rq" ]; then max_rq=$rq; fi

  echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=YES recv_q=$rq bytes_received=$br pid=$pid fd=$fd class=$class backlog_min=$BACKLOG_MIN tag=measured"
  i=$((i + 1))
done

wchar1=$(read_wchar "$pid" 2>/dev/null || echo "")
dwchar=NO-DATA
if [ -n "$wchar0" ] && [ -n "$wchar1" ]; then
  dwchar=$((wchar1 - wchar0))
fi
echo "wchar1=${wchar1:-NO-DATA} d_wchar=$dwchar tag=measured"

# Blindness: should not apply to Recv-Q when we saw nonzero; if ALL ok samples
# were somehow zero-scored incorrectly while work advanced — still check empty-only + work
if [ "$ok_n" -gt 0 ] && [ "$scored_any_nonzero" -eq 0 ] && [ "$empty_n" -eq "$ok_n" ]; then
  # All QUEUE_EMPTY while wchar advanced is NOT "blind counter" — empty is a real value.
  # Blind would be: cannot read recv_q at all while work advances.
  :
fi

if [ "$ok_n" -eq 0 ]; then
  # If process worked but every window NO-DATA → unscored
  echo "SUMMARY ok_n=0 held_n=$held_n low_n=$low_n empty_n=$empty_n nodata_n=$nodata_n"
  echo "RESULT=NO-DATA reason=no_live_scored_windows"
  echo "true rc=77"
  exit 77
fi

# Verdict
verdict=INCONCLUSIVE
if [ "$((held_n * 2))" -ge "$ok_n" ]; then
  verdict=NOT_SUPPLY_LIMITED
fi

echo "SUMMARY ok_n=$ok_n held_n=$held_n low_n=$low_n empty_n=$empty_n nodata_n=$nodata_n min_recv_q=${min_rq:-NO-DATA} max_recv_q=${max_rq:-NO-DATA} backlog_min=$BACKLOG_MIN"
echo "RESULT=$verdict note=no_nominal_bps sustained_BACKLOG_HELD_means_not_input_starved"
echo "INTERPRET held_majority=NOT_SUPPLY_LIMITED empty_majority=INCONCLUSIVE_not_a_defect"
echo "true rc=0"
exit 0
