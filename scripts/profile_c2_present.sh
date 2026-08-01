#!/usr/bin/env bash
# Bounded present-path profiler for the MiSTer. Prefer perf, fall back to
# strace -c, then to /proc thread CPU deltas. Does not touch SPI or restart.
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
DURATION="${DURATION:-30}"
OUT_DIR="/media/fat/misterplex/profiles"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" bash -s -- "$DURATION" "$OUT_DIR" <<'REMOTE'
set -euo pipefail
dur="$1"
out_dir="$2"
pid="$(ps | awk '/misterplexd --name/{print $1; exit}')"
if [[ -z "$pid" ]]; then
  echo "misterplexd not running" >&2
  exit 1
fi
mkdir -p "$out_dir"
echo "pid=$pid duration=${dur}s"

if command -v perf >/dev/null 2>&1; then
  data="$out_dir/c2_perf.data"
  perf record -F 99 -p "$pid" -o "$data" -- sleep "$dur" || true
  perf report -i "$data" --stdio --no-children | head -80 || true
  exit 0
fi

if command -v strace >/dev/null 2>&1; then
  out="$out_dir/c2_strace.txt"
  strace -qq -c -f -p "$pid" -o "$out" &
  spid=$!
  sleep "$dur"
  kill -INT "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  cat "$out"
  exit 0
fi

# Parent 2026-08-01: busybox getconf CLK_TCK can return EMPTY with rc=0.
# `hz=$(getconf ... || echo 100)` does NOT catch empty success → every cpu_pct=0.
ut_st() {
  # utime/stime = rest fields 12/13 AFTER last ')' (comm may contain spaces).
  awk '{
    end=0
    for (i=length($0);i>0;i--) if (substr($0,i,1)==")") { end=i; break }
    if (end==0) exit 2
    rest=substr($0,end+2); n=split(rest,a,/ /)
    if (n<13) exit 2
    print (a[12]+0), (a[13]+0)
  }' "$1"
}
g="$(getconf CLK_TCK 2>/dev/null || true)"
hz=""
src=""
if [[ "$g" =~ ^[1-9][0-9]*$ ]]; then
  hz="$g"; src=getconf
else
  echo "CLK_TCK_GETCONF_EMPTY_OR_BAD raw='${g}' — deriving" >&2
  # Prefer cpu0 (per-CPU HZ). Aggregate "cpu " advances ~ncpu*HZ.
  _j() { awk '/^cpu0 /{s=0;for(i=2;i<=NF;i++)s+=$i;print s;exit} /^cpu /{s=0;for(i=2;i<=NF;i++)s+=$i;print s;exit}' /proc/stat; }
  c0=$(_j); t0=$(date +%s); sleep 1; t1=$(date +%s); c1=$(_j)
  dwall=$((t1 - t0)); dticks=$((c1 - c0))
  if [[ "$dwall" -le 0 || "$dticks" -le 0 ]]; then
    echo "verdict=UNSCORED reason=clk_tck_unresolved"; echo "true rc=77"; exit 77
  fi
  hz=$((dticks / dwall))
  src=derived_proc_stat
  if [[ "$hz" -lt 50 || "$hz" -gt 1500 ]]; then
    echo "verdict=UNSCORED reason=clk_tck_out_of_range hz=$hz"; echo "true rc=77"; exit 77
  fi
fi
echo "HZ=$hz src=$src"
if [[ -z "$hz" || "$hz" -le 0 || -z "$dur" || "$dur" -le 0 ]]; then
  echo "verdict=UNSCORED reason=empty_cpu_denominator hz='$hz' dur='$dur'"
  echo "true rc=77"; exit 77
fi
snap=""
for t in /proc/"$pid"/task/*; do
  tid="${t##*/}"
  vals="$(ut_st "$t/stat")" || continue
  snap="$snap $tid:${vals% *}:${vals#* }"
done
sleep "$dur"
for t in /proc/"$pid"/task/*; do
  tid="${t##*/}"
  vals="$(ut_st "$t/stat")" || continue
  u="${vals% *}"
  s="${vals#* }"
  rec=""
  for x in $snap; do
    case "$x" in "$tid":*) rec="$x" ;; esac
  done
  [[ -z "$rec" ]] && continue
  ou="${rec#*:}"
  os="${ou#*:}"
  ou="${ou%%:*}"
  du=$((u - ou))
  ds=$((s - os))
  cpu=$(((du + ds) * 100 / hz / dur))
  printf 'tid=%s user_ticks=%d sys_ticks=%d cpu_pct=%d comm=%s wchan=%s\n' \
    "$tid" "$du" "$ds" "$cpu" "$(cat "$t/comm")" "$(cat "$t/wchan" 2>/dev/null)"
done | sort -k4 -nr
REMOTE
