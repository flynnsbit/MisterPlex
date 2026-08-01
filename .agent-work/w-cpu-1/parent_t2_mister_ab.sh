#!/bin/sh
# PARENT-RUN ONLY — T2 A/B: MiSTer %onecpu with daemon stopped vs 480p play.
# busybox-safe. Identity via readlink -f /proc/pid/exe (never cmdline).
# Does NOT kill MiSTer. Does NOT rewrite user conf. Does NOT load_core.
#
# Usage (on device, as root):
#   Arm A: stop cast; stop misterplexd (or ensure no ffmpeg); then:
#     sh parent_t2_mister_ab.sh A
#   Arm B: start 480p play; steady; then:
#     sh parent_t2_mister_ab.sh B
#   Optional during B:
#     sh parent_t2_mister_ab.sh strace
#
# Method: ONE window, P=100*dticks/(HZ*dwall), HZ=100
# true rc printed DIRECTLY (not through a pipe).

set -u
LAB=${LAB:-/media/fat/misterplex}
HZ=100
WIN=${WIN:-20}
ARM=${1:-}

mkdir -p "$LAB" 2>/dev/null || true

resolve_pids() {
  M_PID=""; D_PID=""; F_N=0
  for d in /proc/[0-9]*; do
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    base=$(basename "$exe")
    case "$base" in
      MiSTer|mister) M_PID=${d#/proc/} ;;
      misterplexd)   D_PID=${d#/proc/} ;;
      ffmpeg)        F_N=$((F_N + 1)) ;;
    esac
  done
  echo "RESOLVE M_PID=${M_PID:-NO-DATA} D_PID=${D_PID:-NO-DATA} ffmpeg_n=${F_N}"
}

sample_ticks() {
  out=$1
  : > "$out"
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    exe=$(readlink -f "$d/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    [ -r "$d/stat" ] || continue
    raw=$(cat "$d/stat" 2>/dev/null) || continue
    # strip "pid (comm) " — comm may contain spaces/parens
    rest=${raw#*) }
    set -- $rest
    # proc(5): utime=field14 of full stat = field12 of rest; stime=13
    ut=$12
    st=$13
    ticks=$((ut + st))
    echo "$p $ticks $exe" >> "$out"
  done
  awk '/^cpu /{print}' /proc/stat > "${out}.cpu"
}

score_window() {
  label=$1
  a=$2
  b=$3
  wall=$4
  echo "=== ARM $label wall_s=$wall ==="
  awk -v HZ="$HZ" -v W="$wall" -v L="$label" '
    FNR==NR { t1[$1]=$2; next }
    ($1 in t1) {
      dt=$2-t1[$1]
      if (dt<0) next
      p=100.0*dt/(HZ*W)
      exe=$3
      for(i=4;i<=NF;i++) exe=exe" "$i
      base=exe
      sub(/^.*\//,"",base)
      printf "  %6.1f  pid=%s  %s\n", p, $1, exe
      sum+=p
      if (base=="MiSTer" || base=="mister") m+=p
      if (base=="misterplexd") d+=p
      if (base=="ffmpeg") f+=p
    }
    END {
      printf "LABEL=%s MAIN=%.1f DAEMON=%.1f FFMPEG=%.1f SUM_PRINTED=%.1f\n", \
        L, m+0, d+0, f+0, sum+0
    }
  ' "$a" "$b"
}

meta() {
  resolve_pids
  echo "online_cpus=$(cat /sys/devices/system/cpu/online 2>/dev/null)"
  if [ -n "${M_PID:-}" ]; then
    echo "--- MiSTer ---"
    grep -E '^(Name|Cpus_allowed_list|State):' "/proc/$M_PID/status" 2>/dev/null
    awk '{print "nice="$19" rt_prio="$18" policy_f41="$41}' "/proc/$M_PID/stat" 2>/dev/null
  fi
  if [ -n "${D_PID:-}" ]; then
    echo "--- misterplexd ---"
    grep -E '^(Name|Cpus_allowed_list|State):' "/proc/$D_PID/status" 2>/dev/null
    awk '{print "nice="$19" rt_prio="$18" policy_f41="$41}' "/proc/$D_PID/stat" 2>/dev/null
  fi
}

run_arm() {
  label=$1
  echo "START arm=$label win=$WIN"
  meta
  sample_ticks "$LAB/lab_t2_${label}0.txt"
  # wall clock: prefer date +%s (busybox); WIN is authoritative if no subsecond
  sleep "$WIN"
  sample_ticks "$LAB/lab_t2_${label}1.txt"
  score_window "$label" "$LAB/lab_t2_${label}0.txt" "$LAB/lab_t2_${label}1.txt" "$WIN"
  echo "ARM_${label}_done"
  echo "true rc=$?"
}

run_strace() {
  resolve_pids
  if ! command -v strace >/dev/null 2>&1; then
    echo "NO-DATA strace"
    if [ -n "${M_PID:-}" ]; then
      i=0
      : > "$LAB/lab_t2_stack.txt"
      while [ "$i" -lt 30 ]; do
        echo "=== $i ===" >> "$LAB/lab_t2_stack.txt"
        cat "/proc/$M_PID/wchan" 2>/dev/null >> "$LAB/lab_t2_stack.txt"
        echo >> "$LAB/lab_t2_stack.txt"
        cat "/proc/$M_PID/stack" 2>/dev/null >> "$LAB/lab_t2_stack.txt"
        i=$((i + 1))
        sleep 0.05
      done
      echo "stack_samples=30 $LAB/lab_t2_stack.txt"
    fi
    echo "true rc=77"
    return 0
  fi
  if [ -z "${M_PID:-}" ]; then
    echo "NO-DATA M_PID"
    echo "true rc=77"
    return 0
  fi
  strace -c -f -p "$M_PID" 2>"$LAB/lab_t2_strace.txt" &
  SP=$!
  sleep 10
  kill -INT "$SP" 2>/dev/null || true
  wait "$SP" 2>/dev/null
  echo "--- strace -c ---"
  cat "$LAB/lab_t2_strace.txt"
  echo "true rc=$?"
}

case "$ARM" in
  A|a) run_arm A ;;
  B|b) run_arm B ;;
  strace|S) run_strace ;;
  meta) meta; echo "true rc=$?" ;;
  *)
    echo "usage: $0 A|B|strace|meta"
    echo "true rc=2"
    exit 2
    ;;
esac
