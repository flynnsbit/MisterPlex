#!/usr/bin/env bash
# Sample the PLXD frame-store telemetry register over time and report raw values.
#
# PLXD status register 0x300FF12C (BANK_MAILBOX = DOORBELL_PHYS 0x300FF000 + 0x128, upper word)
# 2026-07-28: was 0x3007F12C — one bank stride low, a stale 320p-layout address.
# That address is unwritten DDR, so it read 0x00000000 forever and was mistaken
# for a dead fabric. Field layout (mirrors tests/hw/test_bank_release_visual.sh):
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
PLXD_ADDR="0x300FF12C"
PLXK_ADDR="0x300FF004"   # ARM->FPGA doorbell, upper word: [0]=bank [2:1]=format [31:3]=seq

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

# Sample the ARM doorbell alongside PLXD. Without it, "disp_bank never toggled"
# is uninterpretable: a pinned disp_bank is EXPECTED when no frame was ever
# submitted, and a defect only when frames were submitted and not shown.
PLXK_FIRST=$("${SSH[@]}" "devmem $PLXK_ADDR 32" 2>/dev/null)
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
echo "vsync_count_first=$frames_first vsync_count_last=$frames_last delta=$((frames_last - frames_first))"
echo "NOTE: bits [63:48] are a free-running vsync counter, NOT a swap counter;"
echo "NOTE: advancing here does NOT show that any frame was swapped."
echo "NOTE: free_bank_mask is derived from swap_pending; they are not independent."
PLXK_LAST=$("${SSH[@]}" "devmem $PLXK_ADDR 32" 2>/dev/null)
echo "doorbell_first=${PLXK_FIRST:-UNKNOWN} doorbell_last=${PLXK_LAST:-UNKNOWN}"
if [[ -n "$PLXK_FIRST" && "$PLXK_FIRST" == "$PLXK_LAST" ]]; then
  echo "SUBMISSION_IDLE: doorbell unchanged across the window; no frame was submitted."
  echo "SUBMISSION_IDLE: disp_bank CANNOT toggle with nothing to swap to, so a"
  echo "SUBMISSION_IDLE: pinned disp_bank is not evidence of a fabric fault here."
  SUBMISSION_ACTIVE=0
else
  echo "SUBMISSION_ACTIVE: doorbell changed during the window."
  SUBMISSION_ACTIVE=1
fi

verdict_rc=0
disp_unscored=0
if [[ "$disp_transitions" -lt 2 ]]; then
  if [[ "${SUBMISSION_ACTIVE:-1}" -eq 0 ]]; then
    echo "UNSCORED_DISP_BANK: disp_bank transitions=$disp_transitions, but no frame was"
    echo "UNSCORED_DISP_BANK: submitted during the window. Scoring this as a FAIL would"
    echo "UNSCORED_DISP_BANK: blame the fabric for an idle producer. Re-run with playback."
    disp_unscored=1
  else
    echo "OBSERVABLE_FAIL: disp_bank did not toggle repeatedly (transitions=$disp_transitions, need >=2) despite active frame submission"
    verdict_rc=1
  fi
fi
[[ "$swap_zero" -gt 0 ]] || { echo "OBSERVABLE_FAIL: swap_pending never observed at 0 in $n samples"; verdict_rc=1; }
[[ "$free_nonzero" -gt 0 ]] || { echo "OBSERVABLE_FAIL: free_bank_mask never observed non-zero in $n samples"; verdict_rc=1; }

# The three observables are NOT one signature. The livelock RCA predicted a
# specific joint state: frames_done frozen AND swap_pending latched at 1 AND
# free_bank_mask stuck at 0. Reporting "livelock present" when only disp_bank
# fails would re-assert a diagnosis the data refutes, which is how the wrong
# root cause survived once already. Name the livelock dead or alive on its own
# terms, then report the remaining defect separately.
frames_advancing=0
[[ $((frames_last - frames_first)) -gt 0 ]] && frames_advancing=1
if [[ "$swap_zero" -gt 0 ]]; then
  echo "LIVELOCK_ABSENT: swap_pending cleared in $swap_zero/$n samples — the predicted"
  echo "LIVELOCK_ABSENT: latched swap_pending=1 with free_bank_mask=0 is NOT present."
else
  echo "LIVELOCK_SIGNATURE: frames_advancing=$frames_advancing swap_clears=$swap_zero free_nonzero=$free_nonzero"
fi

if [[ "$verdict_rc" -ne 0 ]]; then
  echo "OBSERVABLES_FAIL: at least one observable did not meet its criterion (see OBSERVABLE_FAIL lines above)"
  exit "$verdict_rc"
fi
if [[ "$disp_unscored" -eq 1 ]]; then
  # A skip is not a pass. Claiming "disp_bank toggles repeatedly" here would
  # assert the single observable this run was unable to test.
  echo "OBSERVABLES_SKIP: swap_pending returned to 0 (livelock signature absent), but"
  echo "OBSERVABLES_SKIP: disp_bank was UNSCORED because no frame was submitted."
  echo "OBSERVABLES_SKIP: this is a SKIP (77), not a PASS."
  exit 77
fi
echo "OBSERVABLES_PASS: disp_bank toggles repeatedly, swap_pending returns to 0, free_bank_mask non-zero"
exit 0
