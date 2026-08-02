#!/bin/sh
# Sample misterplexd RSS over wall time (parent runs on device during soak).
# Defect class: rc=137 at run_s~5k looks like OOM; prove or kill RSS growth.
#
# Resolve daemon by /proc/*/exe only (never cmdline substring — flock trap).
# Usage:
#   sh tools/rss_growth_sample.sh              # one shot
#   INTERVAL_S=30 SAMPLES=20 sh tools/rss_growth_sample.sh
#   sh tools/rss_growth_sample.sh; echo "true rc=$?"
#
# rc: 0 samples ok; 77 NO-DATA (no daemon); 2 multi-match refuse

set -u
INTERVAL_S=${INTERVAL_S:-0}
SAMPLES=${SAMPLES:-1}
EXE_WANT=${EXE_WANT:-misterplexd}

echo "rss_growth_sample INTERVAL_S=$INTERVAL_S SAMPLES=$SAMPLES EXE_WANT=$EXE_WANT"
echo "PRE_REG growth=RSS_kB rises over multi-ks run; flat=no_growth_in_window"

find_pids() {
  for d in /proc/[0-9]*; do
    [ -r "$d/exe" ] || continue
    e=$(readlink -f "$d/exe" 2>/dev/null) || continue
    case "$e" in
      *"$EXE_WANT") echo "${d#/proc/}" ;;
    esac
  done
}

pids=$(find_pids)
n=$(printf '%s\n' "$pids" | grep -c . 2>/dev/null || echo 0)
[ -z "$pids" ] && n=0
if [ "$n" -eq 0 ]; then
  echo "RESULT=NO-DATA reason=no_misterplexd_by_exe"
  exit 77
fi
if [ "$n" -gt 1 ]; then
  echo "RESULT=MULTI_MATCH refuse pids=$pids"
  exit 2
fi
pid=$pids
exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo NO-DATA)
echo "pid=$pid exe=$exe tag=measured"

i=0
while [ "$i" -lt "$SAMPLES" ]; do
  if [ ! -r "/proc/$pid/status" ]; then
    echo "RESULT=GONE pid=$pid sample=$i"
    exit 3
  fi
  rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo NO-DATA)
  peak=$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo NO-DATA)
  threads=$(awk '/^Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo NO-DATA)
  uptime_s=$(awk -v p="$pid" 'BEGIN{while((getline < "/proc/uptime")>0){u=$1}} END{
    if ((getline < ("/proc/" p "/stat"))>0){
      # field 22 starttime ticks; rough: skip complex
    }
  }' 2>/dev/null || true)
  # starttime from stat field 22, HZ=100
  st_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo 0)
  up_ticks=$(awk '{print int($1*100)}' /proc/uptime 2>/dev/null || echo 0)
  run_s=NO-DATA
  if [ -n "$st_ticks" ] && [ -n "$up_ticks" ] && [ "$st_ticks" -gt 0 ] 2>/dev/null; then
    run_s=$(( (up_ticks - st_ticks) / 100 ))
  fi
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)
  echo "ts=$ts sample=$i pid=$pid VmRSS_kB=$rss VmHWM_kB=$peak Threads=$threads run_s=$run_s tag=measured"
  i=$((i + 1))
  if [ "$i" -lt "$SAMPLES" ] && [ "$INTERVAL_S" -gt 0 ]; then
    sleep "$INTERVAL_S"
  fi
done
echo "RESULT=SAMPLED n=$SAMPLES"
exit 0
