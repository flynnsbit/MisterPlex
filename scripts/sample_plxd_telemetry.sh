#!/usr/bin/env bash
# Sample the PLXD frame-store telemetry register over time and report raw values.
#
# PLXD status register 0x3007F12C field layout (mirrors tests/hw/test_bank_release_visual.sh):
#   bits [1:0]   free_bank_mask
#   bit  [2]     disp_bank
#   bit  [3]     swap_pending
#   bits [31:16] frames_done
#
# Usage:
#   ./scripts/sample_plxd_telemetry.sh [samples] [interval_s]
#
# Env:
#   MISTER_HOST  default 192.168.1.183
#   MISTER_PASS  default 1
#   MISTER_USER  default root
#
# Output is raw-first: every sample is printed with its raw 32-bit word before any
# derived verdict. The summary states denominators and never claims a PASS on a
# zero-sample scope.
set -uo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
SAMPLES="${1:-40}"
INTERVAL="${2:-0.25}"
PLXD_ADDR="0x3007F12C"

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$USER@$HOST")

echo "Scope: ${SAMPLES} samples interval=${INTERVAL}s reg=${PLXD_ADDR}"
if [[ "$SAMPLES" -le 0 ]]; then
  echo "REFUSED: Scope: 0 cannot claim a result" >&2
  exit 2
fi

RESIDENT_MD5=$("${SSH[@]}" 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' 2>/dev/null | awk '{print $1}')
CORENAME=$("${SSH[@]}" 'cat /tmp/CORENAME 2>/dev/null' 2>/dev/null | tr -d "\0\r\n")
echo "resident_rbf_md5=${RESIDENT_MD5:-UNKNOWN}"
echo "corename=${CORENAME:-UNKNOWN}"

# Instrument liveness FIRST. DDR contents survive FPGA reconfiguration, so a frozen
# mailbox word is indistinguishable from stale residue left by a previous bitstream.
# Poke a sentinel and require the fabric to overwrite it. Without this, a dead DDR
# write path reads as free_bank_mask=0 swap_pending=1 and is scored as a genuine
# livelock FAIL, which is a false red on a measurement that was never taken.
if [[ "${PLXD_SKIP_LIVENESS:-0}" != "1" ]]; then
  LIVE=$("${SSH[@]}" "
    orig=\$(devmem $PLXD_ADDR 32)
    devmem $PLXD_ADDR 32 0xDEADBEEF
    restored=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.2
      v=\$(devmem $PLXD_ADDR 32)
      if [ \"\$v\" != \"0xDEADBEEF\" ]; then restored=1; break; fi
    done
    if [ \"\$restored\" = \"0\" ]; then devmem $PLXD_ADDR 32 \$orig; fi
    echo \"restored=\$restored\"
  " 2>/dev/null)
  echo "instrument_liveness: $LIVE"
  if [[ "$LIVE" != *"restored=1"* ]]; then
    echo "UNSCORED: fabric did not rewrite $PLXD_ADDR within 2s after a sentinel poke." >&2
    echo "UNSCORED: the PLXD mailbox is not being published by this bitstream, so the" >&2
    echo "UNSCORED: livelock observables are UNMEASURABLE. This is not a livelock FAIL." >&2
    exit 77
  fi
fi

RAW=$("${SSH[@]}" "for i in \$(seq 1 $SAMPLES); do devmem $PLXD_ADDR 32; sleep $INTERVAL; done" 2>/dev/null)
ssh_rc=$?
if [[ $ssh_rc -ne 0 ]]; then
  echo "UNSCORED: telemetry read failed ssh_rc=$ssh_rc" >&2
  exit 77
fi

n=0
prev_disp=""
disp_transitions=0
swap_zero=0
free_nonzero=0
frames_first=""
frames_last=""
declare -A disp_seen=()

while read -r w; do
  [[ -z "$w" ]] && continue
  v=$((w))
  free=$((v & 3))
  disp=$(((v >> 2) & 1))
  swap=$(((v >> 3) & 1))
  frames=$(((v >> 16) & 0xFFFF))
  n=$((n + 1))
  printf 'sample=%d raw=%s free_bank_mask=%d disp_bank=%d swap_pending=%d frames_done=%d\n' \
    "$n" "$w" "$free" "$disp" "$swap" "$frames"
  disp_seen[$disp]=1
  [[ -n "$prev_disp" && "$disp" != "$prev_disp" ]] && disp_transitions=$((disp_transitions + 1))
  prev_disp="$disp"
  [[ "$swap" -eq 0 ]] && swap_zero=$((swap_zero + 1))
  [[ "$free" -ne 0 ]] && free_nonzero=$((free_nonzero + 1))
  [[ -z "$frames_first" ]] && frames_first="$frames"
  frames_last="$frames"
done <<<"$RAW"

echo "---SUMMARY---"
echo "samples_read=$n (requested $SAMPLES)"
if [[ "$n" -eq 0 ]]; then
  echo "UNSCORED: Scope: 0 samples read; no verdict possible" >&2
  exit 77
fi
echo "disp_bank_transitions=$disp_transitions / $((n - 1)) adjacent pairs"
echo "disp_bank_distinct_values=${#disp_seen[@]}"
echo "swap_pending_zero_samples=$swap_zero / $n"
echo "free_bank_mask_nonzero_samples=$free_nonzero / $n"
echo "frames_done_first=$frames_first frames_done_last=$frames_last delta=$((frames_last - frames_first))"

verdict_rc=0
[[ "$disp_transitions" -ge 2 ]] || { echo "OBSERVABLE_FAIL: disp_bank did not toggle repeatedly (transitions=$disp_transitions, need >=2)"; verdict_rc=1; }
[[ "$swap_zero" -gt 0 ]] || { echo "OBSERVABLE_FAIL: swap_pending never observed at 0 in $n samples"; verdict_rc=1; }
[[ "$free_nonzero" -gt 0 ]] || { echo "OBSERVABLE_FAIL: free_bank_mask never observed non-zero in $n samples"; verdict_rc=1; }

if [[ "$verdict_rc" -eq 0 ]]; then
  echo "OBSERVABLES_PASS: disp_bank toggles repeatedly, swap_pending returns to 0, free_bank_mask non-zero"
else
  echo "OBSERVABLES_FAIL: livelock signature still present or partially present"
fi
exit "$verdict_rc"
