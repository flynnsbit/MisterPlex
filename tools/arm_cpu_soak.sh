#!/bin/sh
# Busybox ARM CPU soak sampler — parent-run on device (host self-testable).
#
# FIELD DERIVATIONS (quote every soak — name + derivation together):
#
#   wall_s
#     One sleep window length (argument); wall clock ≈ that sleep.
#
#   HZ = 100
#     Linux jiffy rate used with /proc ticks (DE10-Nano / busybox typical).
#
#   <class>_pct_onecpu  (MiSTer, ffmpeg, misterplexd)
#     P = 100 * dticks / (HZ * wall_s)
#     dticks = Δ(utime+stime) from /proc/<pid>/stat after comm ')'
#     Identity = basename(readlink -f /proc/<pid>/exe) ONLY
#       NEVER cmdline (ERROR 14: flock contains misterplexd)
#       Two roots: /media/fat/misterplex/ and .../misterplex_v2/
#     Missing class ⇒ NO-DATA (never 0.0)
#
#   SYSTEM_BUSY printed X/CAP
#     100 * ncpu * (1 - Δidle/Δtotal) from /proc/stat line field1="cpu"
#     idle = idle + iowait; CAP = 100*ncpu (dual A9 ⇒ 200)
#     Use awk — never `read a b c` (field1 is the label "cpu")
#
#   H1_inelastic = ffmpeg + misterplexd  (Main elastic excluded)
#
#   rbf_md5
#     md5sum of RBF_PATH (default /media/fat/_Utility/Plex.rbf); missing=NO-DATA
#
#   daemon_md5 / daemon_exe
#     md5sum of realpath exe for basename misterplexd (prefer misterplex_v2);
#     missing=NO-DATA
#
#   decode_src
#     DECODE_SRC env, else last decode_src= from LOG (env or probed); else NO-DATA
#     NEVER pool soaks across different decode_src values.
#
#   sampler_self
#     Same P formula for this shell's PID over the window — MEASURED overhead.
#
# Overhead: two /proc walks + sleep; no renice/pin/kill.
# NEVER pgrep/pkill/killall — this tool never kills.
#
# Usage:
#   sh arm_cpu_soak.sh 30
#   sh arm_cpu_soak.sh 120 10
#   RBF_PATH=/media/fat/_Utility/Plex.rbf DECODE_SRC=caller_supplied \
#     LOG=/media/fat/misterplex_v2/misterplexd.log sh arm_cpu_soak.sh 60 10
#   ... ; echo "true rc=$?"

set -eu
SOAK=${1:-30}
INTERVAL=${2:-0}
HZ=100
RBF_PATH=${RBF_PATH:-/media/fat/_Utility/Plex.rbf}
DECODE_SRC=${DECODE_SRC:-}
LOG=${LOG:-}

# Two-roots: prefer live misterplexd install root (exe), then writable fallbacks.
HERE_SOAK=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
if [ -f "$HERE_SOAK/lib_live_misterplex_root.sh" ]; then
  . "$HERE_SOAK/lib_live_misterplex_root.sh"
  if LR=$(resolve_live_misterplex_root 2>/dev/null) && [ -n "$LR" ] && [ -w "$LR" ]; then
    LAB=$LR
  elif [ -d /media/fat/misterplex_v2 ] && [ -w /media/fat/misterplex_v2 ]; then
    LAB=/media/fat/misterplex_v2
  elif [ -d /media/fat/misterplex ] && [ -w /media/fat/misterplex ]; then
    LAB=/media/fat/misterplex
  elif [ -d .agent-work/w-cpu-1 ] && [ -w .agent-work/w-cpu-1 ]; then
    LAB=.agent-work/w-cpu-1
  else
    LAB=.
  fi
elif [ -d /media/fat/misterplex_v2 ] && [ -w /media/fat/misterplex_v2 ]; then
  LAB=/media/fat/misterplex_v2
elif [ -d /media/fat/misterplex ] && [ -w /media/fat/misterplex ]; then
  LAB=/media/fat/misterplex
elif [ -d .agent-work/w-cpu-1 ] && [ -w .agent-work/w-cpu-1 ]; then
  LAB=.agent-work/w-cpu-1
else
  LAB=.
fi

SELF_PID=$$

ncpu_online() {
  if [ -r /sys/devices/system/cpu/online ]; then
    on=$(cat /sys/devices/system/cpu/online)
    case "$on" in
      *-*) a=${on%-*}; b=${on#*-}; echo $((b - a + 1)) ;;
      *,*) echo "$on" | awk -F, '{print NF}' ;;
      *) echo 1 ;;
    esac
  else
    echo 2
  fi
}

file_md5() {
  # stdout: hex or empty
  if [ -r "$1" ]; then
    md5sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

snapshot_procs() {
  out=$1
  : >"$out"
  for d in /proc/[0-9]*; do
    [ -e "$d" ] || continue
    p=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    case "$exe" in
      *" (deleted)") exe=${exe%" (deleted)"} ;;
    esac
    [ -r "$d/stat" ] || continue
    line=$(awk '
      {
        i = index($0, ") ")
        if (i == 0) exit 1
        rest = substr($0, i + 2)
        n = split(rest, a, /[ \t]+/)
        if (n < 13) exit 1
        print a[12] + a[13]
        exit 0
      }' "$d/stat" 2>/dev/null) || continue
    printf '%s %s %s\n' "$p" "$line" "$exe" >>"$out"
  done
}

snapshot_sys() {
  awk '/^cpu /{print; exit}' /proc/stat >"$1"
}

scrape_decode_src() {
  # prints decode_src or empty
  if [ -n "$DECODE_SRC" ]; then
    printf '%s' "$DECODE_SRC"
    return
  fi
  logs="$LOG"
  if [ -z "$logs" ]; then
    logs=""
    if command -v resolve_live_misterplex_log >/dev/null 2>&1 || \
       type resolve_live_misterplex_log >/dev/null 2>&1; then
      if lp=$(resolve_live_misterplex_log 2>/dev/null); then
        logs=$lp
      fi
    fi
    # FALLBACK_ASSUMED paths only after live miss (labelled by helper when used).
    logs="$logs /media/fat/misterplex_v2/misterplexd.log /media/fat/misterplex/misterplexd.log"
  fi
  for lp in $logs; do
    [ -r "$lp" ] || continue
    # tail via dd if needed; busybox tail -c usually exists
    val=$(tail -c 262144 "$lp" 2>/dev/null | tr '\0' '\n' | grep -o 'decode_src=[^ ]*' | tail -n 1 | sed 's/^decode_src=//')
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return
    fi
  done
}

find_daemon_stamp() {
  # sets DAEMON_EXE DAEMON_MD5 DAEMON_PID via stdout lines
  # prefer misterplex_v2
  best_pid=""; best_exe=""; best_rank=9
  for d in /proc/[0-9]*; do
    [ -e "$d" ] || continue
    p=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    base=${exe##*/}
    [ "$base" = "misterplexd" ] || continue
    rank=2
    case "$exe" in
      *misterplex_v2*) rank=0 ;;
      *misterplex*) rank=1 ;;
    esac
    if [ "$rank" -lt "$best_rank" ]; then
      best_rank=$rank
      best_pid=$p
      best_exe=$exe
    fi
  done
  if [ -n "$best_pid" ]; then
    m=$(file_md5 "/proc/$best_pid/exe")
    [ -n "$m" ] || m=$(file_md5 "$best_exe")
    printf 'DAEMON_PID=%s\nDAEMON_EXE=%s\nDAEMON_MD5=%s\n' "$best_pid" "$best_exe" "${m:-}"
  else
    printf 'DAEMON_PID=\nDAEMON_EXE=\nDAEMON_MD5=\n'
  fi
}

sample_once() {
  label=$1
  win=$2
  ncpu=$(ncpu_online)
  tmpa=$LAB/.cpu_a_$$
  tmpb=$LAB/.cpu_b_$$
  sya=${tmpa}.sys
  syb=${tmpb}.sys

  rbf_md5=$(file_md5 "$RBF_PATH")
  [ -n "$rbf_md5" ] || rbf_md5=NO-DATA

  eval "$(find_daemon_stamp)"
  [ -n "${DAEMON_MD5:-}" ] || DAEMON_MD5=NO-DATA
  [ -n "${DAEMON_EXE:-}" ] || DAEMON_EXE=NO-DATA
  [ -n "${DAEMON_PID:-}" ] || DAEMON_PID=NO-DATA

  ds=$(scrape_decode_src)
  [ -n "$ds" ] || ds=NO-DATA

  snapshot_sys "$sya"
  snapshot_procs "$tmpa"
  sleep "$win"
  snapshot_sys "$syb"
  snapshot_procs "$tmpb"

  eval "$(awk -v HZ="$HZ" -v W="$win" -v SPID="$SELF_PID" '
    FNR == NR {
      t1[$1] = $2
      next
    }
    ($1 in t1) {
      dt = $2 - t1[$1]
      if (dt < 0) next
      p = 100.0 * dt / (HZ * W)
      exe = $3
      for (i = 4; i <= NF; i++) exe = exe " " $i
      n = split(exe, parts, "/")
      base = parts[n]
      if (base == "MiSTer" || base == "mister") { m += p; hm = 1 }
      else if (base == "ffmpeg") { f += p; hf = 1 }
      else if (base == "misterplexd") { d += p; hd = 1 }
      if ($1 == SPID) { selfp = p; hs = 1 }
      sum += p
    }
    END {
      if (hm) printf "M=%.1f\n", m; else print "M=NO-DATA"
      if (hf) printf "F=%.1f\n", f; else print "F=NO-DATA"
      if (hd) printf "D=%.1f\n", d; else print "D=NO-DATA"
      if (hf || hd) printf "H1=%.1f\n", (f + 0) + (d + 0); else print "H1=NO-DATA"
      if (hs) printf "SELF=%.1f\n", selfp; else print "SELF=NO-DATA"
      printf "SUM=%.1f\n", sum + 0
    }
  ' "$tmpa" "$tmpb")"

  SB=$(awk -v NCPU="$ncpu" '
    NR == FNR {
      tot0 = 0
      for (i = 2; i <= NF; i++) tot0 += $i
      idle0 = $5 + ($6 + 0)
      next
    }
    {
      tot1 = 0
      for (i = 2; i <= NF; i++) tot1 += $i
      idle1 = $5 + ($6 + 0)
      dt = tot1 - tot0
      di = idle1 - idle0
      if (dt <= 0) { print "NO-DATA"; exit }
      printf "%.1f", 100.0 * NCPU * (dt - di) / dt
    }
  ' "$sya" "$syb")
  CAP=$((ncpu * 100))

  printf 'arm_cpu label=%s wall_s=%s SYSTEM_BUSY=%s/%s MiSTer=%s ffmpeg=%s misterplexd=%s H1_inelastic=%s accounted=%s sampler_self=%s rbf_md5=%s daemon_md5=%s daemon_exe=%s decode_src=%s ncpu=%s method=exe+dticks tag=measured\n' \
    "$label" "$win" "$SB" "$CAP" "$M" "$F" "$D" "$H1" "$SUM" "$SELF" \
    "$rbf_md5" "$DAEMON_MD5" "$DAEMON_EXE" "$ds" "$ncpu"

  rm -f "$tmpa" "$tmpb" "$sya" "$syb" 2>/dev/null || true
}

if [ "$INTERVAL" = "0" ] || [ -z "${INTERVAL}" ]; then
  sample_once single "$SOAK"
else
  end=$(($(date +%s) + SOAK))
  i=0
  while [ "$(date +%s)" -lt "$end" ]; do
    left=$((end - $(date +%s)))
    [ "$left" -lt 1 ] && break
    w=$INTERVAL
    [ "$left" -lt "$w" ] && w=$left
    sample_once "w$i" "$w"
    i=$((i + 1))
  done
  echo "arm_cpu_SOAK_done windows=$i soak_s=$SOAK interval_s=$INTERVAL tag=measured"
fi
