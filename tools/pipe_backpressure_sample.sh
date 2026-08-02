#!/bin/sh
# Live pipe back-pressure sample (ON DEVICE). Read-only. No kill/load_core.
#
# Proves or kills: "ffmpeg is blocked on the rawvideo pipe write because the
# daemon consumes < produce capability."
#
# Method:
#   1) Resolve misterplexd + ffmpeg by readlink -f /proc/*/exe (ERROR 14).
#   2) Pair pipe ends by inode (stat -L %i on /proc/pid/fd/N).
#   3) Sample: ffmpeg state/wchan; optional FIONREAD on daemon read fd via
#      tiny C helper (compiled to ./pipe_fionread_$$ if cc present).
#   4) Liveness: daemon log wall_s must advance (same two-roots helper).
#
# PRE_REGISTER:
#   predict=CONSUMER_BP if majority windows: recv-style pipe_bytes high OR
#            ffmpeg wchan matches pipe_write/pipe_wait AND wall_s live
#   predict=PRODUCER_LIMITED if pipe_bytes low/0 AND ffmpeg not in pipe_write
#            while live collapse (parent vfps low)
#
# Usage:
#   WINDOWS=10 WINDOW_S=2 sh tools/pipe_backpressure_sample.sh
#   sh tools/pipe_backpressure_sample.sh; echo "true rc=$?"
#
# rc: 0 scored; 77 NO-DATA; 2 setup

set -eu

WINDOWS="${WINDOWS:-10}"
WINDOW_S="${WINDOW_S:-2}"
LIVE_MIN_S="${LIVE_MIN_S:-}"
if [ -z "$LIVE_MIN_S" ]; then
  LIVE_MIN_S=$(awk -v w="$WINDOW_S" 'BEGIN { printf "%.3f", (w*0.5 < 0.5 ? 0.5 : w*0.5) }')
fi

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HERE/lib_live_misterplex_root.sh"

echo "pipe_backpressure_sample windows=$WINDOWS window_s=$WINDOW_S live_min_s=$LIVE_MIN_S"
echo "PRE_REGISTER predict=see_RESULT_matrix tag=caller_must_compare_to_collapse"
echo "VOID_rchar=1 note=pipe_fill_via_FIONREAD_or_NO-DATA"

resolve_exe_pid() {
  want=$1
  found=""
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null || true)
    [ -n "$exe" ] || continue
    base=$(basename "$exe")
    case "$base" in
      "$want"|${want}_*) found="$pid $exe" ;;
    esac
  done
  [ -n "$found" ] || return 1
  # prefer last match (usually newest); v2 path rank
  best=""; best_r=9
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null || true)
    [ -n "$exe" ] || continue
    base=$(basename "$exe")
    case "$base" in
      "$want"|${want}_*)
        r=2
        case "$exe" in *misterplex_v2*) r=0 ;; *misterplex*) r=1 ;; esac
        if [ -z "$best" ] || [ "$r" -le "$best_r" ]; then
          best="$pid $exe"; best_r=$r
        fi
        ;;
    esac
  done
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

# Build FIONREAD helper if possible (once).
FIONREAD_BIN=""
build_fionread() {
  src=${TMPDIR:-/var/tmp}/pipe_fionread_$$.c
  bin=${TMPDIR:-/var/tmp}/pipe_fionread_$$
  # Prefer CWD under tools if /var/tmp not writable — use HERE
  src="$HERE/.pipe_fionread_$$.c"
  bin="$HERE/.pipe_fionread_$$"
  cat >"$src" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
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
  if command -v cc >/dev/null 2>&1; then
    if cc -O0 -o "$bin" "$src" 2>/dev/null; then
      FIONREAD_BIN=$bin
      rm -f "$src"
      return 0
    fi
  fi
  if command -v gcc >/dev/null 2>&1; then
    if gcc -O0 -o "$bin" "$src" 2>/dev/null; then
      FIONREAD_BIN=$bin
      rm -f "$src"
      return 0
    fi
  fi
  rm -f "$src"
  return 1
}

cleanup() {
  [ -n "${FIONREAD_BIN:-}" ] && rm -f "$FIONREAD_BIN" 2>/dev/null || true
  rm -f "$HERE"/.pipe_fionread_$$ "$HERE"/.pipe_fionread_$$.c 2>/dev/null || true
}
trap cleanup EXIT

if ! dline=$(resolve_exe_pid misterplexd); then
  echo "RESULT=NO-DATA reason=no_misterplexd_exe"
  exit 77
fi
if ! fline=$(resolve_exe_pid ffmpeg); then
  echo "RESULT=NO-DATA reason=no_ffmpeg_exe"
  exit 77
fi
dpid=${dline%% *}
dexe=${dline#* }
fpid=${fline%% *}
fexe=${fline#* }
echo "daemon_pid=$dpid daemon_exe=$dexe tag=measured"
echo "ffmpeg_pid=$fpid ffmpeg_exe=$fexe tag=measured"

# Map fd -> inode for both; find shared pipe inodes
# busybox stat may support -L -c %i
pair_read_fd=""
pair_write_fd=""
pair_ino=""

list_fd_inos() {
  pid=$1
  for link in /proc/$pid/fd/*; do
    [ -e "$link" ] || continue
    fd=${link##*/}
    tgt=$(readlink "$link" 2>/dev/null || true)
    case "$tgt" in
      pipe:*|pipe:\[*\])
        ino=$(stat -L -c %i "$link" 2>/dev/null || stat -f %i "$link" 2>/dev/null || echo "")
        [ -n "$ino" ] || continue
        printf '%s %s %s\n' "$fd" "$ino" "$tgt"
        ;;
    esac
  done
}

d_pipes=$(list_fd_inos "$dpid" || true)
f_pipes=$(list_fd_inos "$fpid" || true)
if [ -z "$d_pipes" ] || [ -z "$f_pipes" ]; then
  echo "RESULT=NO-DATA reason=no_pipe_fds_listed"
  exit 77
fi

# Match inode
echo "$d_pipes" | while read -r dfd dino _; do
  echo "$f_pipes" | while read -r ffd fino _; do
    if [ "$dino" = "$fino" ]; then
      echo "PAIR ino=$dino daemon_fd=$dfd ffmpeg_fd=$ffd tag=measured"
    fi
  done
done >"$HERE/.pipe_pairs_$$" 2>/dev/null || true

# Take first pair
if [ -f "$HERE/.pipe_pairs_$$" ]; then
  first=$(head -n 1 "$HERE/.pipe_pairs_$$" || true)
  rm -f "$HERE/.pipe_pairs_$$"
else
  first=""
fi
if [ -z "$first" ]; then
  echo "RESULT=NO-DATA reason=no_shared_pipe_inode"
  echo "daemon_pipes:"
  echo "$d_pipes"
  echo "ffmpeg_pipes:"
  echo "$f_pipes"
  exit 77
fi
echo "$first"
pair_ino=$(echo "$first" | sed -n 's/.*ino=\([0-9]*\).*/\1/p')
pair_read_fd=$(echo "$first" | sed -n 's/.*daemon_fd=\([0-9]*\).*/\1/p')
pair_write_fd=$(echo "$first" | sed -n 's/.*ffmpeg_fd=\([0-9]*\).*/\1/p')

fionread_ok=0
if build_fionread; then
  fionread_ok=1
  echo "fionread_helper=built tag=measured"
else
  echo "fionread_helper=NO-DATA note=no_cc_on_device"
fi

# Open daemon read fd via /proc (same open file description — FIONREAD works)
READ_PATH=/proc/$dpid/fd/$pair_read_fd

wall0=$(read_wall_s || true)
echo "wall_s_start=${wall0:-NO-DATA}"

i=0
live_n=0
bp_n=0
prod_n=0
nodata_n=0
while [ "$i" -lt "$WINDOWS" ]; do
  # wall liveness vs previous
  wall=$(read_wall_s || true)
  st=$(awk '{print $3}' /proc/$fpid/stat 2>/dev/null || echo "?")
  wchan=$(cat /proc/$fpid/wchan 2>/dev/null || cat /proc/$fpid/syscall 2>/dev/null | awk '{print $1}' || echo "?")
  # some kernels export wchan as 0
  wchan_name=$(cat /proc/$fpid/wchan 2>/dev/null || echo "NO-DATA")
  dst=$(awk '{print $3}' /proc/$dpid/stat 2>/dev/null || echo "?")

  bytes="NO-DATA"
  if [ "$fionread_ok" -eq 1 ] && [ -e "$READ_PATH" ]; then
    # helper needs FD number in *this* process — open via exec redirection
    # Use dd? no. Re-open path:
    bytes=$(
      # shell opens path as fd 3
      exec 3<"$READ_PATH" 2>/dev/null || exit 0
      "$FIONREAD_BIN" 3 2>/dev/null || true
      exec 3<&-
    ) || bytes="NO-DATA"
    [ -n "$bytes" ] || bytes="NO-DATA"
  fi

  live=0
  if [ -n "${wall0:-}" ] && [ -n "${wall:-}" ]; then
    # compare later
    :
  fi

  echo "s$i wall_s=${wall:-NO-DATA} ffmpeg_state=$st ffmpeg_wchan=$wchan_name daemon_state=$dst pipe_bytes=$bytes pipe_bytes_src=$([ "$bytes" = NO-DATA ] && echo NO-DATA || echo measured) tag=measured"

  # classify window (wchan heuristic)
  case "$wchan_name" in
    *pipe_write*|*pipe_wait*|*unix_stream_sendmsg*|*wait_for_partner*)
      bp_n=$((bp_n + 1))
      echo "  window_class=CONSUMER_BP_HINT wchan_match=1"
      ;;
    *)
      if [ "$bytes" != "NO-DATA" ] && [ "$bytes" -gt 400000 ] 2>/dev/null; then
        bp_n=$((bp_n + 1))
        echo "  window_class=CONSUMER_BP_HINT pipe_bytes_high=1"
      elif [ "$bytes" = "0" ] || [ "$bytes" = "NO-DATA" ]; then
        prod_n=$((prod_n + 1))
        echo "  window_class=PRODUCER_OR_EMPTY_HINT"
      else
        nodata_n=$((nodata_n + 1))
        echo "  window_class=AMBIGUOUS"
      fi
      ;;
  esac

  i=$((i + 1))
  if [ "$i" -lt "$WINDOWS" ]; then
    sleep "$WINDOW_S"
  fi
done

wall1=$(read_wall_s || true)
echo "wall_s_end=${wall1:-NO-DATA}"
live_ok=0
if [ -n "${wall0:-}" ] && [ -n "${wall1:-}" ]; then
  adv=$(awk -v a="$wall0" -v b="$wall1" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.3f", d}')
  need=$LIVE_MIN_S
  echo "wall_s_advance=$adv live_min_s=$need tag=measured"
  if awk -v d="$adv" -v n="$need" 'BEGIN{exit !(d+0>=n+0)}'; then
    live_ok=1
  fi
else
  echo "wall_s_advance=NO-DATA"
fi

if [ "$live_ok" -ne 1 ]; then
  echo "RESULT=NO-DATA reason=wall_s_not_advancing_or_missing note=playback_may_have_ended"
  exit 77
fi

echo "tally bp_hint=$bp_n producer_or_empty_hint=$prod_n ambiguous=$nodata_n windows=$WINDOWS tag=measured"
if [ "$bp_n" -gt $((WINDOWS / 2)) ]; then
  echo "RESULT=CONSUMER_BP_HINT majority_windows_match_backpressure_signature"
  echo "note=HINT_not_proof_cross_check_present_profile"
  exit 0
fi
if [ "$prod_n" -gt $((WINDOWS / 2)) ]; then
  echo "RESULT=PRODUCER_LIMITED_HINT majority_empty_or_no_pipe_wait"
  exit 0
fi
echo "RESULT=AMBIGUOUS"
exit 0
