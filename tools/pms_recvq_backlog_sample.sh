#!/bin/sh
# PMS TCP Recv-Q backlog during a REAL product cast (ON DEVICE).
# Parent-only. Read-only. No core/load_core/kill.
#
# =============================================================================
# VOID (do not reintroduce):
#   - /proc/pid/io rchar — blind to recv() (syscr=5); blind RED STALL 12/12
#   - NOMINAL_BPS / any hardcoded rate threshold — ERROR 17 family.
#     Even a correct recv counter stalls at 0.4*57000=22800 B/s while real
#     healthy arrival was ~9851 B/s (parent rd-review addendum).
# =============================================================================
#
# Method:
#   1) ffmpeg pid via readlink -f /proc/pid/exe (ERROR 14).
#   2) Pin socket by TCP **4-tuple** (local:port peer:port), NOT fd=N.
#      -reconnect* may reuse fd 5 and reset bytes_received — a DECREASE in
#      bytes_received is RECONNECT, never a rate sample.
#   3) Score Recv-Q backlog (kernel: rcv_nxt - copied_seq). No assumed nominal.
#   4) Derive consume_Bps = (Δbr − Δrecv_q) / Δt ; backlog_depth_s = recv_q / consume_Bps.
#   5) Report recv_q / rcv_ssthresh (receive-side). Do NOT cite app_limited.
#   6) MANDATORY liveness: daemon wall_s advances ≥ LIVE_MIN_S each window.
#   7) Default WINDOW_S=6 (≥ parent ~6 s burst) to reduce aliasing; short windows
#      print ALIAS_WARN — backlog_depth_s is the assumption-light statistic.
#
# PRE-REGISTER (per session — do NOT carry healthy-clip predict onto collapse):
#   Healthy banked clip (e.g. low-bitrate 624x480): predict NOT_SUPPLY_LIMITED
#     (held_n majority, depth_s large).
#   Collapsing high-bitrate clip on slow link: predict SUPPLY_LIMITED / QUEUE_EMPTY
#     — parent 2026-08-01 rk=9: empty_n=8/8 max_recv_q=0 while audio_s/wall≈0.47.
#   MISS published: carrying predict_verdict=NOT_SUPPLY_LIMITED onto rk=9 collapse
#     was wrong; empty Recv-Q = starved (not pipe back-pressure).
#
# Usage:
#   WINDOWS=6 WINDOW_S=6 BACKLOG_MIN=100000 sh tools/pms_recvq_backlog_sample.sh
#   echo "true rc=$?"
#
# rc: 0 scored; 77 NO-DATA; 2 setup

set -eu

WINDOWS="${WINDOWS:-6}"
WINDOW_S="${WINDOW_S:-6}"
BACKLOG_MIN="${BACKLOG_MIN:-100000}"
LIVE_MIN_S="${LIVE_MIN_S:-}"
FFMPEG_EXE_SUBSTR="${FFMPEG_EXE_SUBSTR:-ffmpeg}"
FFMPEG_PID="${FFMPEG_PID:-}"
SS_BIN="${SS_BIN:-/usr/sbin/ss}"
[ -x "$SS_BIN" ] || SS_BIN="$(command -v ss 2>/dev/null || true)"
LOG_HINT="${LOG_HINT:-}"
BURST_HINT_S="${BURST_HINT_S:-6}"

if [ -z "$LIVE_MIN_S" ]; then
  LIVE_MIN_S=$(awk -v w="$WINDOW_S" 'BEGIN { printf "%.3f", (w*0.5 < 0.5 ? 0.5 : w*0.5) }')
fi

echo "pms_recvq_backlog_sample windows=$WINDOWS window_s=$WINDOW_S backlog_min=$BACKLOG_MIN live_min_s=$LIVE_MIN_S"
echo "VOID_rchar=1 VOID_nominal_bps=1 pin=four_tuple note=reconnect_if_bytes_received_decreases"
echo "PRE_REGISTER note=set_predict_per_session_see_header_MISS_rk9_empty_was_starved"
if awk -v w="$WINDOW_S" -v b="$BURST_HINT_S" 'BEGIN { exit !(w+0 < b+0) }'; then
  echo "ALIAS_WARN window_s=$WINDOW_S < burst_hint_s=$BURST_HINT_S — prefer WINDOW_S>=$BURST_HINT_S; trust backlog_depth_s over short gaps"
fi

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
  [ -n "$found" ] || return 1
  echo "$found"
}

read_wall_s() {
  # Two-roots: resolve log from live misterplexd exe, not hardcoded v1/v2 order.
  HERE_RQ=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
  # shellcheck disable=SC1091
  . "$HERE_RQ/lib_live_misterplex_root.sh"
  pick=""
  if pick=$(resolve_live_misterplex_log "${LOG_HINT:-}"); then
    :
  else
    pick=""
  fi
  line=""
  if [ -n "$pick" ]; then
    line=$(grep "wall_s=" "$pick" 2>/dev/null | tail -n 1 || true)
  else
    line=$(logread 2>/dev/null | grep "wall_s=" | tail -n 1 || true)
  fi
  echo "$line" | sed -n 's/.*[^a-z_]wall_s=\([0-9.][0-9.]*\).*/\1/p' | tail -n 1
}

# Print: recv_q bytes_received rcv_ssthresh four_tuple fd
# four_tuple is "local peer" with a space — we use | as field sep in output.
ss_sample() {
  pid=$1
  tuple_pin=$2   # empty = discover; else must match "local peer"
  blob=$("$SS_BIN" -tinp 2>/dev/null || true)
  [ -n "$blob" ] || return 1

  # awk: build records, pick best for pid (prefer :32400 peer)
  echo "$blob" | awk -v pid="$pid" -v pin="$tuple_pin" '
    function flush(    rq, br, ss, loc, pr, fd, tup, pms, n, a, i, st) {
      if (buf == "") return
      if (index(buf, "pid=" pid) == 0) { buf=""; return }
      rq = -1; br = -1; ss = -1; loc = ""; pr = ""; fd = -1
      if (match(buf, /fd=[0-9]+/)) {
        fd = substr(buf, RSTART+3, RLENGTH-3) + 0
      }
      if (match(buf, /bytes_received:[0-9]+/)) {
        br = substr(buf, RSTART+15, RLENGTH-15) + 0
      }
      if (match(buf, /rcv_ssthresh:[0-9]+/)) {
        ss = substr(buf, RSTART+13, RLENGTH-13) + 0
      }
      # head line
      n = split(head, a, /[ \t]+/)
      # find ESTAB-like and two addr tokens
      for (i = 1; i <= n; i++) {
        if (a[i] ~ /^(ESTAB|ESTABLISHED|FIN-WAIT|CLOSE-WAIT|SYN-)/) {
          if (i+1 <= n && a[i+1] ~ /^[0-9]+$/) rq = a[i+1] + 0
          # next non-numeric with colon = local, then peer
          j = i + 3
          while (j <= n && a[j] !~ /:/) j++
          if (j <= n) { loc = a[j]; j++ }
          while (j <= n && a[j] !~ /:/) j++
          if (j <= n) pr = a[j]
          break
        }
      }
      if (rq < 0 && match(buf, /Recv-Q[ \t:]+[0-9]+/)) {
        # fallback
        line = substr(buf, RSTART, RLENGTH)
        split(line, b, /[ \t:]+/)
        for (k in b) if (b[k] ~ /^[0-9]+$/) { rq = b[k]+0; break }
      }
      if (rq < 0) { buf=""; head=""; return }
      tup = loc " " pr
      if (pin != "" && tup != pin) { buf=""; head=""; return }
      pms = (pr ~ /:32400$/) ? 1 : 0
      # keep best
      if (best_rq < 0 || (pin != "") || (pms && best_pms == 0) || rq > best_rq) {
        best_rq = rq; best_br = br; best_ss = ss; best_tup = tup; best_fd = fd; best_pms = pms
      }
      buf = ""; head = ""
    }
    BEGIN { best_rq = -1; best_br = -1; best_ss = -1; best_tup = ""; best_fd = -1; best_pms = 0; buf=""; head="" }
    {
      indented = ($0 ~ /^[ \t]/)
      if (!indented && buf != "") flush()
      if (!indented) head = $0
      if (buf != "") buf = buf "\n" $0
      else buf = $0
    }
    END {
      flush()
      if (best_rq < 0) exit 1
      brs = (best_br >= 0) ? best_br : "NO-DATA"
      sss = (best_ss >= 0) ? best_ss : "NO-DATA"
      # | separated: rq|br|ssthresh|tuple|fd
      printf "%d|%s|%s|%s|%d\n", best_rq, brs, sss, best_tup, best_fd
    }
  '
}

res=$(resolve_ffmpeg_pid) || {
  echo "RESULT=NO-DATA reason=no_ffmpeg"
  echo "true rc=77"
  exit 77
}
pid=${res%% *}
exe=${res#* }
echo "ffmpeg_pid=$pid exe=$exe resolve=readlink_exe tag=measured"

# Discover 4-tuple once
first=$(ss_sample "$pid" "") || {
  echo "RESULT=NO-DATA reason=ss_no_socket"
  echo "true rc=77"
  exit 77
}
# parse first
oifs=$IFS
IFS='|'
set -- $first
IFS=$oifs
pin_rq=$1; pin_br=$2; pin_ss=$3; PIN_TUPLE=$4; pin_fd=$5
echo "four_tuple=$PIN_TUPLE fd=$pin_fd note=fd_informational_only pin=four_tuple tag=measured"
echo "seed recv_q=$pin_rq bytes_received=$pin_br rcv_ssthresh=$pin_ss tag=measured"

i=1
ok_n=0
held_n=0
low_n=0
empty_n=0
nodata_n=0
recon_n=0
min_rq=""
max_rq=""
min_depth=""
max_depth=""
prev_br=""
prev_rq=""
# seed prev from first snapshot so first window can compute deltas
if [ "$pin_br" != "NO-DATA" ]; then prev_br=$pin_br; fi
prev_rq=$pin_rq

while [ "$i" -le "$WINDOWS" ]; do
  if [ ! -d "/proc/$pid" ]; then
    echo "sample=$i RESULT=NO-DATA reason=pid_gone live=NO"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  fi

  w0=$(read_wall_s || true)
  u0=$(awk '{print $1}' /proc/uptime)

  sleep "$WINDOW_S"

  w1=$(read_wall_s || true)
  u1=$(awk '{print $1}' /proc/uptime)
  samp=$(ss_sample "$pid" "$PIN_TUPLE" || true)

  dwall=$(awk -v a="$u0" -v b="$u1" 'BEGIN { d=b-a; if (d<=0) exit 1; printf "%.3f", d }') || {
    echo "sample=$i RESULT=NO-DATA reason=bad_uptime"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  }

  live=NO
  dw_sess=NO-DATA
  if [ -n "$w0" ] && [ -n "$w1" ]; then
    live=$(awk -v a="$w0" -v b="$w1" -v m="$LIVE_MIN_S" 'BEGIN { d=b-a; if (d>=m) print "YES"; else print "NO" }')
    dw_sess=$(awk -v a="$w0" -v b="$w1" 'BEGIN { printf "%.3f", b-a }')
  fi

  if [ "$live" != "YES" ]; then
    echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=NO RESULT=NO-DATA reason=session_wall_s_not_advancing wall0=${w0:-NO-DATA} wall1=${w1:-NO-DATA}"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  fi

  if [ -z "$samp" ]; then
    # tuple missing — possible reconnect to new 4-tuple
    alt=$(ss_sample "$pid" "" || true)
    if [ -n "$alt" ]; then
      echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=YES class=RECONNECT reason=four_tuple_gone new=$alt note=bytes_received_reset_expected tag=measured"
      recon_n=$((recon_n + 1))
      # re-pin
      oifs=$IFS; IFS='|'; set -- $alt; IFS=$oifs
      PIN_TUPLE=$4
      prev_br=""; prev_rq=$1
      if [ "$2" != "NO-DATA" ]; then prev_br=$2; fi
      echo "re_pin four_tuple=$PIN_TUPLE tag=measured"
    else
      echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=YES RESULT=NO-DATA reason=ss_parse_fail"
      nodata_n=$((nodata_n + 1))
    fi
    i=$((i + 1))
    continue
  fi

  oifs=$IFS; IFS='|'; set -- $samp; IFS=$oifs
  rq=$1; br=$2; ssth=$3; tup=$4; fd=$5

  recon=0
  if [ -n "$prev_br" ] && [ "$br" != "NO-DATA" ]; then
    if [ "$br" -lt "$prev_br" ] 2>/dev/null; then
      recon=1
    fi
  fi

  if [ "$recon" -eq 1 ]; then
    echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=YES recv_q=$rq bytes_received=$br class=RECONNECT reason=bytes_received_decreased prev_br=$prev_br note=not_a_rate_sample four_tuple=$tup tag=measured"
    recon_n=$((recon_n + 1))
    prev_br=$br
    prev_rq=$rq
    i=$((i + 1))
    continue
  fi

  # consume_Bps and depth_s
  consume=NO-DATA
  depth=NO-DATA
  if [ -n "$prev_br" ] && [ "$br" != "NO-DATA" ] && [ -n "$prev_rq" ]; then
    eval $(awk -v pr="$prev_rq" -v cr="$rq" -v pb="$prev_br" -v cb="$br" -v dw="$dwall" 'BEGIN {
      arrived = cb - pb
      if (arrived < 0) { print "consume=NO-DATA"; print "depth=NO-DATA"; exit 0 }
      drq = cr - pr
      cons = arrived - drq
      if (cons < 0 && cons > -4096) cons = 0
      if (cons < 0 || dw <= 0) { print "consume=NO-DATA"; print "depth=NO-DATA"; exit 0 }
      bps = cons / dw
      printf "consume=%.1f\n", bps
      if (bps > 0) printf "depth=%.2f\n", cr / bps
      else print "depth=NO-DATA"
    }')
  fi

  rq_over=NO-DATA
  if [ "$ssth" != "NO-DATA" ] && [ "$ssth" -gt 0 ] 2>/dev/null; then
    rq_over=$(awk -v r="$rq" -v s="$ssth" 'BEGIN { printf "%.2f", r/s }')
  fi

  class=NO-DATA
  if [ "$rq" -eq 0 ] 2>/dev/null; then
    class=QUEUE_EMPTY
    empty_n=$((empty_n + 1))
  elif [ "$rq" -ge "$BACKLOG_MIN" ] 2>/dev/null; then
    class=BACKLOG_HELD
    held_n=$((held_n + 1))
  elif [ "$rq" -gt 0 ] 2>/dev/null; then
    class=BACKLOG_LOW
    low_n=$((low_n + 1))
  else
    echo "sample=$i RESULT=NO-DATA reason=bad_recv_q"
    nodata_n=$((nodata_n + 1))
    i=$((i + 1))
    continue
  fi

  ok_n=$((ok_n + 1))
  if [ -z "$min_rq" ] || [ "$rq" -lt "$min_rq" ]; then min_rq=$rq; fi
  if [ -z "$max_rq" ] || [ "$rq" -gt "$max_rq" ]; then max_rq=$rq; fi
  if [ "$depth" != "NO-DATA" ]; then
    if [ -z "$min_depth" ] || awk -v a="$depth" -v b="$min_depth" 'BEGIN{exit !(a<b)}'; then min_depth=$depth; fi
    if [ -z "$max_depth" ] || awk -v a="$depth" -v b="$max_depth" 'BEGIN{exit !(a>b)}'; then max_depth=$depth; fi
  fi

  echo "sample=$i d_wall_s=$dwall session_d_wall_s=$dw_sess live=YES recv_q=$rq bytes_received=$br rcv_ssthresh=$ssth recv_q_over_ssthresh=$rq_over consume_Bps=$consume backlog_depth_s=$depth four_tuple=$tup fd=$fd class=$class note=no_nominal_bps_no_app_limited pin=four_tuple tag=measured"

  prev_br=$br
  prev_rq=$rq
  i=$((i + 1))
done

if [ "$ok_n" -eq 0 ]; then
  echo "SUMMARY ok_n=0 held_n=$held_n low_n=$low_n empty_n=$empty_n reconnect_n=$recon_n nodata_n=$nodata_n"
  echo "RESULT=NO-DATA reason=no_live_scored_windows"
  echo "true rc=77"
  exit 77
fi

verdict=INCONCLUSIVE
if [ "$((held_n * 2))" -ge "$ok_n" ]; then
  verdict=NOT_SUPPLY_LIMITED
elif [ -n "$min_depth" ] && awk -v d="$min_depth" 'BEGIN{exit !(d>=5.0)}'; then
  verdict=NOT_SUPPLY_LIMITED
fi

echo "SUMMARY ok_n=$ok_n held_n=$held_n low_n=$low_n empty_n=$empty_n reconnect_n=$recon_n nodata_n=$nodata_n min_recv_q=${min_rq:-NO-DATA} max_recv_q=${max_rq:-NO-DATA} min_backlog_depth_s=${min_depth:-NO-DATA} max_backlog_depth_s=${max_depth:-NO-DATA} backlog_min=$BACKLOG_MIN"
echo "RESULT=$verdict note=NOT_SUPPLY_LIMITED_if_held_majority_or_depth_s_ge_5"
echo "INTERPRET depth_s=recv_q/consume_Bps consume_Bps=(d_br-d_rq)/d_wall reconnect_excluded_from_rate"
echo "true rc=0"
exit 0
