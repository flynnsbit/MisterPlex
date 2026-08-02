#!/bin/sh
# Read-only OOM / SIGKILL (rc=137) probe for MiSTer host. Parent runs on device.
# Does not kill, restart, load_core, or write outside stdout.
#
# PRE_REGISTER:
#   HIT  = kernel log contains OOM-killer lines naming misterplexd (or child)
#          OR /proc/meminfo shows absurd pressure at sample time (supporting only)
#   MISS = scanned sources do NOT contain those strings
#          MISS is "log does not contain X" — NOT "OOM never happened"
#          (dmesg ring rotates; no persistent journal on many MiSTer images)
#
# Usage:
#   sh tools/oom_sigkill_probe.sh
#   sh tools/oom_sigkill_probe.sh; echo "true rc=$?"
#
# rc: 0 = ran; printed HIT or MISS; 77 = NO-DATA (no log source readable)

set -u

echo "oom_sigkill_probe PRE_REGISTER HIT=oom_kill_lines_name_misterplexd MISS=log_does_not_contain"
echo "note=MISS_is_not_proof_OOM_never_happened ring_buffer_may_rotate"

HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HERE/lib_live_misterplex_root.sh"

ROOT=""
if ROOT=$(resolve_live_misterplex_root); then
  echo "ROOT=$ROOT"
else
  echo "ROOT=NO-DATA"
fi

hit=0
sources=0
miss_reasons=""

scan_blob() {
  label=$1
  blob=$2
  sources=$((sources + 1))
  echo "=== source=$label bytes=${#blob} provenance=measured ==="
  if [ -z "$blob" ]; then
    echo "log_does_not_contain (empty read) source=$label"
    miss_reasons="$miss_reasons empty:$label"
    return
  fi
  # Show any OOM-ish lines (cap)
  echo "$blob" | grep -iE 'Out of memory|oom-kill|Killed process|Memory cgroup out of|oom_reaper' | tail -n 40 || true
  if echo "$blob" | grep -qiE 'Out of memory|oom-kill|Killed process'; then
    if echo "$blob" | grep -iE 'Out of memory|oom-kill|Killed process' | grep -qiE 'misterplexd|ffmpeg'; then
      echo "CLASS=HIT_OOM_NAMED tag=measured source=$label"
      hit=1
    else
      echo "CLASS=HIT_OOM_OTHER_PROCESS tag=measured source=$label note=OOM_seen_but_not_our_name"
      hit=1
    fi
  else
    echo "log_does_not_contain OOM-killer phrases source=$label tag=measured"
    miss_reasons="$miss_reasons no_oom_phrase:$label"
  fi
}

# dmesg (primary on MiSTer)
if DMESG=$(dmesg 2>/dev/null); then
  scan_blob "dmesg" "$DMESG"
else
  echo "=== source=dmesg provenance=NO-DATA (dmesg failed) ==="
fi

# Common persistent logs if present
for f in /var/log/messages /var/log/kern.log /var/log/syslog; do
  if [ -r "$f" ]; then
    blob=$(tail -n 5000 "$f" 2>/dev/null || true)
    scan_blob "$f" "$blob"
  fi
done

echo "=== meminfo snapshot provenance=measured ==="
if [ -r /proc/meminfo ]; then
  grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|AnonPages|SReclaimable):' /proc/meminfo || true
else
  echo "NO-DATA /proc/meminfo"
fi

echo "=== supervise rc=137 count (if logs) provenance=measured|NO-DATA ==="
if [ -n "$ROOT" ] && [ -f "$ROOT/misterplexd_supervise.log" ]; then
  n137=$(grep -cE 'EXIT pid=.*rc=137' "$ROOT/misterplexd_supervise.log" 2>/dev/null || echo 0)
  echo "rc137_lines=$n137 path=$ROOT/misterplexd_supervise.log tag=measured"
  grep -E 'EXIT pid=.*rc=137' "$ROOT/misterplexd_supervise.log" 2>/dev/null | tail -n 8 || true
else
  echo "NO-DATA supervise log for rc=137"
fi

echo "=== death files (SIGKILL leaves NO handler witness) ==="
if [ -n "$ROOT" ] && [ -f "$ROOT/misterplexd.death" ]; then
  echo "death_present=1 note=SIGKILL_cannot_write_via_handler; file may be prior TERM/SEGV"
  cat "$ROOT/misterplexd.death"
else
  echo "NO-DATA death (expected for pure SIGKILL; also expected if never written)"
fi

if [ "$sources" -eq 0 ]; then
  echo "RESULT=NO-DATA reason=no_readable_kernel_log_source"
  exit 77
fi

if [ "$hit" -eq 1 ]; then
  echo "RESULT=HIT_OOM_EVIDENCE_IN_LOG"
  exit 0
fi

echo "RESULT=MISS_LOG_DOES_NOT_CONTAIN_OOM"
echo "miss_detail=$miss_reasons"
echo "interpret=cannot_rule_out_historical_OOM_if_dmesg_rotated"
exit 0
