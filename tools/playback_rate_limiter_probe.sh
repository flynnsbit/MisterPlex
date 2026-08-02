#!/bin/sh
# Settle what caps 480p playback below path capacity (parent 2026-08-02).
# ON DEVICE. Read-only. No kill/load_core/conf write.
#
# Parent facts:
#   path ~108 KB/s; playback alone ~47 KB/s (does not fill path)
#   Recv-Q empty 8/8 on collapse (vs naive HTTP back-pressure)
#
# Same windows sample:
#   A) rawvideo pipe FIONREAD + ffmpeg wchan
#   B) ss -tin: recv_q rcv_space rcv_ssthresh cwnd rtt bytes_received rate
#   C) wall_s liveness
#
# PRE_REGISTER:
#   H-A CONSUMER_BP: pipe_bytes≳449280 OR wchan pipe_write; often recv_q high
#     OR (pipe full + recv_q empty = ffmpeg drained socket into internal bufs)
#     FALSIFY: pipe_bytes=0 AND wchan≠pipe_write majority (parent empty recv_q
#     alone does NOT prove H-A — need pipe/wchan)
#   H-B PER_CONN_RWND: rcv_space small (<64KiB) stable; pipe empty; wchan≠pipe;
#     recv_q empty; second conn can still fill path
#     FALSIFY: rcv_space large while rate stays ~47KB/s
#   H-C SENDER_PACED: pipe empty; wchan≠pipe; recv_q empty; rcv_space healthy;
#     rate~47KB/s with proven spare path
#     FALSIFY: pipe full or wchan pipe_write majority
#
# empty probe = NO-DATA never 0.0. pid via readlink -f exe (ERROR 14).
# Usage:
#   WINDOWS=10 WINDOW_S=2 sh tools/playback_rate_limiter_probe.sh
#   ...; echo "true rc=$?"
# rc: 0 scored; 77 NO-DATA; 2 setup

set -eu

WINDOWS="${WINDOWS:-10}"
WINDOW_S="${WINDOW_S:-2}"
LIVE_MIN_S="${LIVE_MIN_S:-}"
FFMPEG_EXE_SUBSTR="${FFMPEG_EXE_SUBSTR:-ffmpeg}"
SS_BIN="${SS_BIN:-}"
[ -n "$SS_BIN" ] || SS_BIN=$(command -v ss 2>/dev/null || true)
FRAME_HINT_B="${FRAME_HINT_B:-449280}"

if [ -z "$LIVE_MIN_S" ]; then
  LIVE_MIN_S=$(awk -v w="$WINDOW_S" 'BEGIN { printf "%.3f", (w*0.5 < 0.5 ? 0.5 : w*0.5) }')
fi

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HERE/lib_live_misterplex_root.sh"

echo "playback_rate_limiter_probe windows=$WINDOWS window_s=$WINDOW_S live_min_s=$LIVE_MIN_S"
echo "PRE_REGISTER H-A=CONSUMER_BP H-B=PER_CONN_RWND H-C=SENDER_PACED"
echo "PREDICT_LEAD=H-B_or_H-C note=H-A_needs_pipe_or_wchan_not_recv_q_alone"
echo "VOID empty=NO-DATA_never_zero ERROR14=readlink_exe"

resolve_want() {
  want=$1
  best=""; best_r=9
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null || true)
    [ -n "$exe" ] || continue
    base=$(basename "$exe")
    ok=0
    case "$base" in
      "$want"|${want}_*) ok=1 ;;
    esac
    case "$exe" in *"$want"*) ok=1 ;; esac
    [ "$ok" -eq 1 ] || continue
    r=2
    case "$exe" in *misterplex_v2*) r=0 ;; *misterplex*) r=1 ;; esac
    if [ -z "$best" ] || [ "$r" -le "$best_r" ]; then
      best="$pid $exe"; best_r=$r
    fi
  done
  [ -n "$best" ] || return 1
  echo "$best"
}

read_wall_s() {
  pick=""
  if pick=$(resolve_live_misterplex_log "${LOG_HINT:-}" 2>/dev/null); then
    :
  else
    pick=""
  fi
  line=""
  if [ -n "$pick" ] && [ -f "$pick" ]; then
    line=$(grep "wall_s=" "$pick" 2>/dev/null | tail -n 1 || true)
  fi
  echo "$line" | sed -n 's/.*[^a-z_]wall_s=\([0-9.][0-9.]*\).*/\1/p' | tail -n 1
}

FIONREAD_BIN=""
build_fionread() {
  src="$HERE/.playback_fionread_$$.c"
  bin="$HERE/.playback_fionread_$$"
  cat >"$src" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ioctl.h>
int main(int argc, char** argv) {
  if (argc != 2) return 2;
  int fd = atoi(argv[1]);
  int n = -1;
  if (ioctl(fd, FIONREAD, &n) != 0) return 1;
  printf("%d\n", n);
  return 0;
}
CEOF
  FIONREAD_BIN=""
  if command -v cc >/dev/null 2>&1 && cc -O0 -o "$bin" "$src" 2>/dev/null; then
    FIONREAD_BIN=$bin
  elif command -v gcc >/dev/null 2>&1 && gcc -O0 -o "$bin" "$src" 2>/dev/null; then
    FIONREAD_BIN=$bin
  fi
  rm -f "$src"
  [ -n "$FIONREAD_BIN" ]
}
cleanup() { [ -n "${FIONREAD_BIN:-}" ] && rm -f "$FIONREAD_BIN" 2>/dev/null || true; }
trap cleanup EXIT

list_pipes() {
  pid=$1
  lab=$2
  for f in /proc/$pid/fd/*; do
    [ -e "$f" ] || continue
    fd=${f##*/}
    link=$(readlink "$f" 2>/dev/null || true)
    case "$link" in
      pipe:\[*\])
        ino=$(echo "$link" | sed -n 's/pipe:\[\([0-9]*\)\]/\1/p')
        printf '%s\t%s\t%s\n' "$lab" "$fd" "$ino"
        ;;
    esac
  done
}

# ss fields one line for pid (optional pin "local peer")
ss_tcp_fields() {
  pid=$1
  pin=$2
  if [ -z "$SS_BIN" ] || [ ! -x "$SS_BIN" ]; then
    echo "NO-DATA"
    return 1
  fi
  blob=$("$SS_BIN" -tinp 2>/dev/null || true)
  [ -n "$blob" ] || { echo "NO-DATA"; return 1; }
  echo "$blob" | awk -v pid="$pid" -v pin="$pin" '
    function flush(    rq, br, rs, ss, cw, rt, dr, loc, pr, tup, pms, n, a, i, j) {
      if (buf == "") return
      if (index(buf, "pid=" pid) == 0) { buf=""; head=""; return }
      rq=-1; br=-1; rs=-1; ss=-1; cw=-1; rt=-1; dr=-1; loc=""; pr=""
      n = split(head, a, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (a[i] ~ /^(ESTAB|ESTABLISHED)/) {
          if (i+1 <= n && a[i+1] ~ /^[0-9]+$/) rq = a[i+1]+0
          j = i + 3
          while (j <= n && a[j] !~ /:/) j++
          if (j <= n) { loc=a[j]; j++ }
          while (j <= n && a[j] !~ /:/) j++
          if (j <= n) pr=a[j]
          break
        }
      }
      if (match(buf, /bytes_received:[0-9]+/)) br = substr(buf, RSTART+15, RLENGTH-15)+0
      if (match(buf, /rcv_space:[0-9]+/)) rs = substr(buf, RSTART+10, RLENGTH-10)+0
      if (match(buf, /rcv_ssthresh:[0-9]+/)) ss = substr(buf, RSTART+13, RLENGTH-13)+0
      if (match(buf, /cwnd:[0-9]+/)) cw = substr(buf, RSTART+5, RLENGTH-5)+0
      if (match(buf, /rtt:[0-9.]+/)) {
        rt = substr(buf, RSTART+4, RLENGTH-4)+0
      }
      if (match(buf, /delivery_rate [0-9.]+/))
        dr = substr(buf, RSTART+14, RLENGTH-14)+0
      tup = loc " " pr
      if (pin != "" && tup != pin) { buf=""; head=""; return }
      pms = (pr ~ /:32400$/) ? 1 : 0
      if (best_set == 0 || pin != "" || (pms && !best_pms) || (pms == best_pms && br >= best_br)) {
        best_set=1; best_rq=rq; best_br=br; best_rs=rs; best_ss=ss
        best_cw=cw; best_rt=rt; best_dr=dr; best_tup=tup; best_pms=pms
      }
      buf=""; head=""
    }
    BEGIN { best_set=0; best_pms=0; best_br=-1; buf=""; head="" }
    {
      ind = ($0 ~ /^[ \t]/)
      if (!ind && buf != "") flush()
      if (!ind) head=$0
      buf = (buf=="" ? $0 : buf "\n" $0)
    }
    END {
      flush()
      if (!best_set) { print "NO-DATA"; exit 1 }
      printf "recv_q=%s bytes_received=%s rcv_space=%s rcv_ssthresh=%s cwnd=%s rtt_ms=%s delivery_rate_Mbps=%s four_tuple=%s\n",
        (best_rq>=0?best_rq:"NO-DATA"), (best_br>=0?best_br:"NO-DATA"),
        (best_rs>=0?best_rs:"NO-DATA"), (best_ss>=0?best_ss:"NO-DATA"),
        (best_cw>=0?best_cw:"NO-DATA"), (best_rt>=0?best_rt:"NO-DATA"),
        (best_dr>=0?best_dr:"NO-DATA"), (best_tup!=""?best_tup:"NO-DATA")
    }'
}

dres=$(resolve_want misterplexd) || { echo "RESULT=NO-DATA reason=no_misterplexd"; exit 77; }
dpid=${dres%% *}; dexe=${dres#* }
fres=$(resolve_want ffmpeg) || {
  fres=""
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null || true)
    case "$exe" in *"$FFMPEG_EXE_SUBSTR"*) fres="$pid $exe" ;; esac
  done
  [ -n "$fres" ] || { echo "RESULT=NO-DATA reason=no_ffmpeg"; exit 77; }
}
fpid=${fres%% *}; fexe=${fres#* }
echo "misterplexd_pid=$dpid exe=$dexe tag=measured"
echo "ffmpeg_pid=$fpid exe=$fexe tag=measured"

if [ -r /proc/sys/net/ipv4/tcp_rmem ]; then
  echo "tcp_rmem=$(tr '\t' ' ' </proc/sys/net/ipv4/tcp_rmem) tag=measured"
else
  echo "tcp_rmem=NO-DATA"
fi
if [ -r /proc/sys/fs/pipe-max-size ]; then
  echo "pipe_max_size=$(cat /proc/sys/fs/pipe-max-size) tag=measured"
else
  echo "pipe_max_size=NO-DATA"
fi

d_pipes=$(list_pipes "$dpid" d)
f_pipes=$(list_pipes "$fpid" f)
pairfile="$HERE/.playback_pairs_$$"
: >"$pairfile"
echo "$d_pipes" | while IFS=$(printf '\t') read -r lab dfd dino; do
  [ -n "$dino" ] || continue
  echo "$f_pipes" | while IFS=$(printf '\t') read -r flab ffd fino; do
    if [ "$dino" = "$fino" ]; then
      echo "ino=$dino daemon_fd=$dfd ffmpeg_fd=$ffd"
    fi
  done
done >"$pairfile"

if [ ! -s "$pairfile" ]; then
  echo "rawvideo_pair=NO-DATA reason=no_shared_pipe_inode"
  echo "daemon_pipes:"
  echo "$d_pipes"
  echo "ffmpeg_pipes:"
  echo "$f_pipes"
  pair_read_fd=""
else
  echo "rawvideo_pair_candidates:"
  cat "$pairfile"
  # Prefer pair where we can FIONREAD largest later; select LAST (often video after audio)
  last=$(tail -n 1 "$pairfile")
  echo "rawvideo_pair_selected=$last note=last_shared_inode"
  pair_read_fd=$(echo "$last" | sed -n 's/.*daemon_fd=\([0-9]*\).*/\1/p')
  pair_write_fd=$(echo "$last" | sed -n 's/.*ffmpeg_fd=\([0-9]*\).*/\1/p')
fi
rm -f "$pairfile"

fionread_ok=0
if build_fionread; then
  fionread_ok=1
  echo "fionread_helper=built tag=measured"
else
  echo "fionread_helper=NO-DATA note=no_cc"
fi
READ_PATH=""
[ -n "${pair_read_fd:-}" ] && READ_PATH=/proc/$dpid/fd/$pair_read_fd

seed=$(ss_tcp_fields "$fpid" "") || seed="NO-DATA"
echo "tcp_seed $seed tag=measured"
pin_tuple=""
case "$seed" in
  *four_tuple=*) pin_tuple=$(echo "$seed" | sed -n 's/.*four_tuple=//p' | sed 's/[[:space:]]*$//') ;;
esac
echo "tcp_pin_tuple=${pin_tuple:-NO-DATA}"

prev_br="NO-DATA"
prev_ts=0
wall0=$(read_wall_s || true)
echo "wall_s_start=${wall0:-NO-DATA}"

i=0
ha_n=0; hb_n=0; hc_n=0; amb_n=0
pipe_hi_n=0; pipe_zero_n=0; pipe_nodata_n=0; wchan_pipe_n=0
recv_empty_n=0; recv_held_n=0
br_rate_sum=0; br_rate_n=0

while [ "$i" -lt "$WINDOWS" ]; do
  wall=$(read_wall_s || true)
  st=$(awk '{print $3}' /proc/$fpid/stat 2>/dev/null || echo "NO-DATA")
  wchan_name=$(cat /proc/$fpid/wchan 2>/dev/null || echo "NO-DATA")
  [ -n "$wchan_name" ] || wchan_name="NO-DATA"
  dst=$(awk '{print $3}' /proc/$dpid/stat 2>/dev/null || echo "NO-DATA")

  pipe_bytes="NO-DATA"
  if [ "$fionread_ok" -eq 1 ] && [ -n "$READ_PATH" ] && [ -e "$READ_PATH" ]; then
    pipe_bytes=$(
      exec 3<"$READ_PATH" 2>/dev/null || exit 0
      "$FIONREAD_BIN" 3 2>/dev/null || true
      exec 3<&-
    ) || pipe_bytes="NO-DATA"
    [ -n "$pipe_bytes" ] || pipe_bytes="NO-DATA"
  fi

  tcp=$(ss_tcp_fields "$fpid" "$pin_tuple") || tcp="NO-DATA"
  if [ "$tcp" = "NO-DATA" ]; then
    tcp=$(ss_tcp_fields "$fpid" "") || tcp="NO-DATA"
  fi

  rq=$(echo "$tcp" | sed -n 's/.*recv_q=\([^ ]*\).*/\1/p')
  br=$(echo "$tcp" | sed -n 's/.*bytes_received=\([^ ]*\).*/\1/p')
  rs=$(echo "$tcp" | sed -n 's/.*rcv_space=\([^ ]*\).*/\1/p')
  sst=$(echo "$tcp" | sed -n 's/.*rcv_ssthresh=\([^ ]*\).*/\1/p')
  cw=$(echo "$tcp" | sed -n 's/.*cwnd=\([^ ]*\).*/\1/p')
  rt=$(echo "$tcp" | sed -n 's/.*rtt_ms=\([^ ]*\).*/\1/p')
  : "${rq:=NO-DATA}" "${br:=NO-DATA}" "${rs:=NO-DATA}" "${sst:=NO-DATA}" "${cw:=NO-DATA}" "${rt:=NO-DATA}"

  # wall clock for rate (not session wall_s — avoid NO-DATA stall)
  now_ts=$(date +%s)
  br_rate="NO-DATA"
  if [ "$br" != "NO-DATA" ] && [ "$prev_br" != "NO-DATA" ] && [ "$prev_ts" -gt 0 ]; then
    dt=$((now_ts - prev_ts))
    if [ "$dt" -gt 0 ]; then
      # shell arithmetic only if both integers
      dbr=$((br - prev_br)) || dbr=-1
      if [ "$dbr" -ge 0 ] 2>/dev/null; then
        br_rate=$(awk -v d="$dbr" -v t="$dt" 'BEGIN{printf "%.1f", d/t}')
        br_rate_sum=$(awk -v s="$br_rate_sum" -v r="$br_rate" 'BEGIN{printf "%.3f", s+r}')
        br_rate_n=$((br_rate_n + 1))
      else
        br_rate="RECONNECT"
      fi
    fi
  fi
  prev_br=$br
  prev_ts=$now_ts

  psrc=NO-DATA
  [ "$pipe_bytes" != "NO-DATA" ] && psrc=measured
  echo "s$i wall_s=${wall:-NO-DATA} ffmpeg_state=$st ffmpeg_wchan=$wchan_name daemon_state=$dst pipe_bytes=$pipe_bytes pipe_bytes_src=$psrc recv_q=$rq bytes_received=$br rcv_space=$rs rcv_ssthresh=$sst cwnd=$cw rtt_ms=$rt br_rate_Bps=$br_rate tag=measured"

  case "$wchan_name" in
    *pipe_write*|*pipe_wait*|*unix_stream_sendmsg*) wchan_pipe_n=$((wchan_pipe_n + 1)) ;;
  esac
  if [ "$pipe_bytes" = "NO-DATA" ]; then
    pipe_nodata_n=$((pipe_nodata_n + 1))
  elif [ "$pipe_bytes" -ge "$FRAME_HINT_B" ] 2>/dev/null; then
    pipe_hi_n=$((pipe_hi_n + 1))
  elif [ "$pipe_bytes" = "0" ]; then
    pipe_zero_n=$((pipe_zero_n + 1))
  fi
  if [ "$rq" = "0" ]; then
    recv_empty_n=$((recv_empty_n + 1))
  elif [ "$rq" != "NO-DATA" ] && [ "$rq" -gt 50000 ] 2>/dev/null; then
    recv_held_n=$((recv_held_n + 1))
  fi

  class=AMBIGUOUS
  if [ "$pipe_bytes" != "NO-DATA" ] && [ "$pipe_bytes" -ge "$FRAME_HINT_B" ] 2>/dev/null; then
    class=H-A_CONSUMER_BP; ha_n=$((ha_n + 1))
  else
    case "$wchan_name" in
      *pipe_write*|*pipe_wait*|*unix_stream_sendmsg*)
        class=H-A_CONSUMER_BP; ha_n=$((ha_n + 1))
        ;;
      *)
        if [ "$rs" != "NO-DATA" ] && [ "$rs" -gt 0 ] 2>/dev/null && [ "$rs" -lt 65536 ] 2>/dev/null; then
          class=H-B_SMALL_RCV_SPACE; hb_n=$((hb_n + 1))
        elif [ "$pipe_bytes" = "0" ] || [ "$pipe_bytes" = "NO-DATA" ]; then
          if [ "$rq" = "0" ] || [ "$rq" = "NO-DATA" ]; then
            class=H-C_SENDER_OR_DRAINED; hc_n=$((hc_n + 1))
          else
            amb_n=$((amb_n + 1))
          fi
        else
          amb_n=$((amb_n + 1))
        fi
        ;;
    esac
  fi
  echo "  window_class=$class"

  i=$((i + 1))
  [ "$i" -lt "$WINDOWS" ] && sleep "$WINDOW_S"
done

wall1=$(read_wall_s || true)
echo "wall_s_end=${wall1:-NO-DATA}"
live_ok=0
if [ -n "${wall0:-}" ] && [ -n "${wall1:-}" ]; then
  adv=$(awk -v a="$wall0" -v b="$wall1" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.3f", d}')
  echo "wall_s_advance=$adv live_min_s=$LIVE_MIN_S tag=measured"
  awk -v d="$adv" -v n="$LIVE_MIN_S" 'BEGIN{exit !(d+0>=n+0)}' && live_ok=1
else
  echo "wall_s_advance=NO-DATA"
fi

if [ "$live_ok" -ne 1 ]; then
  echo "RESULT=NO-DATA reason=wall_s_not_advancing"
  exit 77
fi

br_avg=NO-DATA
[ "$br_rate_n" -gt 0 ] && br_avg=$(awk -v s="$br_rate_sum" -v n="$br_rate_n" 'BEGIN{printf "%.1f", s/n}')

echo "=== tallies tag=measured ==="
echo "ha_consumer_bp=$ha_n hb_small_rcv=$hb_n hc_sender_or_drained=$hc_n ambiguous=$amb_n windows=$WINDOWS"
echo "pipe_hi_n=$pipe_hi_n pipe_zero_n=$pipe_zero_n pipe_nodata_n=$pipe_nodata_n wchan_pipe_n=$wchan_pipe_n"
echo "recv_empty_n=$recv_empty_n recv_held_n=$recv_held_n br_rate_avg_Bps=$br_avg"
echo "INTERPRET H-A needs pipe full OR wchan pipe_write — empty recv_q alone is NOT H-A"
echo "INTERPRET H-B small rcv_space + empty pipe + empty recv_q"
echo "INTERPRET H-C empty pipe + non-pipe wchan + empty recv_q + large rcv_space"

maj=$((WINDOWS / 2))
if [ "$ha_n" -gt "$maj" ]; then
  echo "RESULT=H-A_CONSUMER_BACKPRESSURE_HINT"
  exit 0
fi
if [ "$hb_n" -gt "$maj" ]; then
  echo "RESULT=H-B_PER_CONN_SMALL_RCV_SPACE_HINT"
  exit 0
fi
if [ "$hc_n" -gt "$maj" ]; then
  echo "RESULT=H-C_SENDER_PACED_OR_NON_PIPE_LIMIT_HINT"
  exit 0
fi
echo "RESULT=AMBIGUOUS"
exit 0
