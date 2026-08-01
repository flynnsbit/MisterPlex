#!/bin/sh
# Busybox ARM CPU soak sampler — parent-run on device (also host-self-testable).
#
# Method (quote in every soak report):
#   Per-process %onecpu: P = 100 * dticks / (HZ * dwall)
#     ticks = utime+stime from /proc/<pid>/stat (fields after comm)
#   Identity: readlink -f /proc/<pid>/exe ONLY
#     NEVER cmdline substring (ERROR 14: flock cmdline contains misterplexd)
#     NEVER name-match alone (two roots: /media/fat/misterplex{,_v2}/)
#   Absence of a watched class = NO-DATA (never print 0.0 for missing)
#   SYSTEM_BUSY = 100 * ncpu * (1 - Δidle/Δtotal)
#     from the /proc/stat line whose field1 is the literal label "cpu"
#     (use awk — `read a b c` fails because field1 is "cpu")
#   H1_inelastic = ffmpeg + misterplexd  (elastic Main excluded)
#
# Overhead: two /proc walks per window + sleep. No renice/kill/pin.
# Expect sampler self << 1 %onecpu for window >= 5 s on DE10-Nano.
#
# Usage:
#   sh tools/arm_cpu_soak.sh 30            # one 30 s window
#   sh tools/arm_cpu_soak.sh 120 10         # 120 s soak, 10 s windows
# Always capture:  sh tools/arm_cpu_soak.sh 30; echo "true rc=$?"
# NEVER pgrep / pkill / killall — kill by numeric PID only if ever needed (this tool never kills).
#
# Output one line per window, e.g.:
#   arm_cpu label=w0 wall_s=10 SYSTEM_BUSY=169.0/200 MiSTer=90.6 ffmpeg=69.6
#     misterplexd=25.6 H1_inelastic=95.2 accounted=162.8 method=exe+dticks ncpu=2 tag=measured

set -eu
SOAK=${1:-30}
INTERVAL=${2:-0}
HZ=100

if [ -d /media/fat/misterplex ] && [ -w /media/fat/misterplex ]; then
  LAB=/media/fat/misterplex
elif [ -d .agent-work/w-cpu-1 ] && [ -w .agent-work/w-cpu-1 ]; then
  LAB=.agent-work/w-cpu-1
else
  LAB=.
fi

ncpu_online() {
  if [ -r /sys/devices/system/cpu/online ]; then
    on=$(cat /sys/devices/system/cpu/online)
    case "$on" in
      *-*)
        a=${on%-*}
        b=${on#*-}
        echo $((b - a + 1))
        ;;
      *,*)
        echo "$on" | awk -F, '{print NF}'
        ;;
      *)
        echo 1
        ;;
    esac
  else
    # DE10-Nano dual A9 default when sysfs missing
    echo 2
  fi
}

# Write lines: pid ticks exe_path
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
        ticks = a[12] + a[13]
        print ticks
        exit 0
      }' "$d/stat" 2>/dev/null) || continue
    printf '%s %s %s\n' "$p" "$line" "$exe" >>"$out"
  done
}

snapshot_sys() {
  awk '/^cpu /{print; exit}' /proc/stat >"$1"
}

sample_once() {
  label=$1
  win=$2
  ncpu=$(ncpu_online)
  tmpa=$LAB/.cpu_a_$$
  tmpb=$LAB/.cpu_b_$$
  sya=${tmpa}.sys
  syb=${tmpb}.sys

  snapshot_sys "$sya"
  snapshot_procs "$tmpa"
  sleep "$win"
  snapshot_sys "$syb"
  snapshot_procs "$tmpb"

  eval "$(awk -v HZ="$HZ" -v W="$win" '
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
      sum += p
    }
    END {
      if (hm) printf "M=%.1f\n", m; else print "M=NO-DATA"
      if (hf) printf "F=%.1f\n", f; else print "F=NO-DATA"
      if (hd) printf "D=%.1f\n", d; else print "D=NO-DATA"
      if (hf || hd) printf "H1=%.1f\n", (f + 0) + (d + 0); else print "H1=NO-DATA"
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

  printf 'arm_cpu label=%s wall_s=%s SYSTEM_BUSY=%s/%s MiSTer=%s ffmpeg=%s misterplexd=%s H1_inelastic=%s accounted=%s method=exe+dticks ncpu=%s tag=measured\n' \
    "$label" "$win" "$SB" "$CAP" "$M" "$F" "$D" "$H1" "$SUM" "$ncpu"

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
