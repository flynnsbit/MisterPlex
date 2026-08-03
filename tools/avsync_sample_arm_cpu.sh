#!/usr/bin/env bash
# Sample misterplexd ARM CPU% over ~2s via /proc (busybox: pidof, no pgrep).
# Parent runs this concurrently with HDMI capture. Emits JSON on stdout.
# Identify process only by resolved /proc/<pid>/exe (parent rule).
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  "${USER}@${HOST}" 'sh -s' <<'REMOTE'
set -e
pid=""
for p in /proc/[0-9]*; do
  pid_n=${p#/proc/}
  exe=$(readlink -f "$p/exe" 2>/dev/null || true)
  case "$exe" in
    */misterplexd) pid=$pid_n; break ;;
  esac
done
if [ -z "$pid" ]; then
  for cand in $(pidof misterplexd 2>/dev/null || true); do
    exe=$(readlink -f /proc/$cand/exe 2>/dev/null || true)
    case "$exe" in
      */misterplexd) pid=$cand; break ;;
    esac
  done
fi
if [ -z "$pid" ]; then
  echo '{"arm_cpu_pct":null,"arm_cpu_pct_src":"NO-DATA","note":"misterplexd_not_found"}'
  exit 0
fi
read ut1 st1 <<EOF1
$(awk '{print $14, $15}' /proc/$pid/stat)
EOF1
read _ user1 nice1 sys1 idle1 rest1 <<EOF2
$(head -1 /proc/stat)
EOF2
total1=$((user1+nice1+sys1+idle1))
sleep 2
read ut2 st2 <<EOF3
$(awk '{print $14, $15}' /proc/$pid/stat)
EOF3
read _ user2 nice2 sys2 idle2 rest2 <<EOF4
$(head -1 /proc/stat)
EOF4
total2=$((user2+nice2+sys2+idle2))
proc=$(( (ut2+st2) - (ut1+st1) ))
total=$(( total2 - total1 ))
[ "$total" -gt 0 ] || total=1
pct=$(awk -v p="$proc" -v t="$total" 'BEGIN { printf "%.2f", (100.0*p)/t }')
exe=$(readlink -f /proc/$pid/exe 2>/dev/null || echo unknown)
echo "{\"arm_cpu_pct\":$pct,\"arm_cpu_pct_src\":\"measured\",\"pid\":$pid,\"exe\":\"$exe\",\"sample_s\":2,\"note\":\"jiffies_proc_over_system_2s\"}"
REMOTE
