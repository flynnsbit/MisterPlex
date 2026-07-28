#!/usr/bin/env bash
# Freshness probe: prove the ARM is writing the DDR frame bank *now*.
#
# What this literally does:
#   Writes a poison pattern over the first N 32-bit words of a frame bank,
#   confirms the poison is readable (so the write landed), then polls until the
#   ARM's idle repaint restores the byte-exact product payload.
#
# What it does NOT cover:
#   - Anything about the FPGA. The fabric is not involved: this reads and writes
#     DDR from the ARM side only.
#   - Whether the frame is ever displayed. A restored bank says the ARM wrote
#     the right bytes, not that anything scanned them out.
#   - Playback. Idle logo only; playback has a different publish cadence.
#
# Why it exists:
#   DDR contents survive FPGA reconfiguration. So a byte-exact match against a
#   live bank is ambiguous: it could be a fresh ARM write, or residue written
#   before a core reload / RBF deploy. Every mailbox word in this system is
#   subject to the same ambiguity -- W-FIT demonstrated a "live" PLXF magic that
#   was pure residue from a previous bitstream. Content comparison alone cannot
#   tell fresh from stale. Overwriting and watching it heal can.
#
#   Note the doorbell is NOT a substitute: measured, the ARM restores the bank
#   without bumping PLXK seq for a static idle screen, so db_seq can sit still
#   across a real repaint.
#
# How to make it fail:
#   Stop misterplexd and run it -- nothing restores the poison, and it exits 1
#   after the timeout with the poison still in place. Or set
#   IDLE_FRESH_NO_RESTORE=1 to skip the ARM entirely and prove the timeout path.
#
# Exit: 0 restored (ARM is live), 1 not restored, 77 unscored.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/tests/hw/hw_gate_common.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER_NAME="${MISTER_USER:-root}"
BANK="${1:-0}"
# 3x the 30s static-idle repaint safety net in MediaPlayer::startIdle().
TIMEOUT_S="${IDLE_FRESH_TIMEOUT_S:-100}"
POISON_WORDS="${IDLE_FRESH_WORDS:-4}"
OUT="$ROOT/build/idle_freshness"
mkdir -p "$OUT"

command -v sshpass >/dev/null 2>&1 || \
  hw_skip_not_pass "test_idle_ddr_freshness" "sshpass is not installed"

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
     -o LogLevel=ERROR "$USER_NAME@$HOST")

"${SSH[@]}" 'echo DEVICE_OK' > "$OUT/preflight.txt" 2>&1
if ! grep -q DEVICE_OK "$OUT/preflight.txt"; then
  hw_skip_not_pass "test_idle_ddr_freshness" "device $HOST unreachable"
fi

"${SSH[@]}" 'command -v devmem >/dev/null && echo HAVE_DEVMEM' > "$OUT/devmem.txt" 2>&1
grep -q HAVE_DEVMEM "$OUT/devmem.txt" || \
  hw_skip_not_pass "test_idle_ddr_freshness" "devmem not available on $HOST"

LAYOUT_ARGS=$(python3 "$ROOT/scripts/ddr_layout_consts.py" --dump-args)
[[ -n "$LAYOUT_ARGS" ]] || { echo "FAIL cannot derive DDR layout" >&2; exit 1; }

DDR_BASE=$(python3 -c "import sys;a=sys.argv[1:];print(a[a.index('--ddr-base')+1])" $LAYOUT_ARGS)
STRIDE=$(python3 -c "import sys;a=sys.argv[1:];print(a[a.index('--bank-stride')+1])" $LAYOUT_ARGS)
BANK_BASE=$(python3 -c "print(hex(int('$DDR_BASE',0) + $BANK*int('$STRIDE',0)))")

echo "Scope: $POISON_WORDS 32-bit words ($((POISON_WORDS*4)) bytes) poisoned in bank $BANK at $BANK_BASE; denominator = full frame payload, restore within ${TIMEOUT_S}s"

ADDRS=()
for ((i = 0; i < POISON_WORDS; i++)); do
  ADDRS+=("$(python3 -c "print(hex(int('$BANK_BASE',0) + $i*4))")")
done

# Record the originals so this probe is reversible even if the ARM never heals.
"${SSH[@]}" "for a in ${ADDRS[*]}; do devmem \$a 32; done" > "$OUT/original.txt" 2>&1
mapfile -t ORIGINAL < "$OUT/original.txt"
if [[ ${#ORIGINAL[@]} -ne $POISON_WORDS ]]; then
  hw_skip_not_pass "test_idle_ddr_freshness" \
    "could not read original words (got ${#ORIGINAL[@]}/$POISON_WORDS)"
fi
echo "ORIGINAL ${ORIGINAL[*]}"

restore_originals() {
  local cmd="" i
  for ((i = 0; i < POISON_WORDS; i++)); do
    cmd+="devmem ${ADDRS[$i]} 32 ${ORIGINAL[$i]}; "
  done
  "${SSH[@]}" "$cmd" >> "$OUT/restore.txt" 2>&1
  echo "RESTORED originals written back by the probe"
}

if [[ "${IDLE_FRESH_NO_RESTORE:-0}" == "1" ]]; then
  echo "IDLE_FRESH_NO_RESTORE=1: exercising the timeout path, ARM heal is not awaited"
fi

POISON=0xDEADBEEF
"${SSH[@]}" "for a in ${ADDRS[*]}; do devmem \$a 32 $POISON; done" > "$OUT/poison.txt" 2>&1
"${SSH[@]}" "for a in ${ADDRS[*]}; do devmem \$a 32; done" > "$OUT/poison_read.txt" 2>&1
POISONED=$(grep -ci "deadbeef" "$OUT/poison_read.txt")
echo "POISON_LANDED $POISONED/$POISON_WORDS words read back as $POISON"
if [[ "$POISONED" -ne "$POISON_WORDS" ]]; then
  restore_originals
  hw_skip_not_pass "test_idle_ddr_freshness" \
    "poison did not land ($POISONED/$POISON_WORDS); cannot distinguish fresh from stale"
fi

START=$(date +%s)
RESTORED_AT=""
while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  [[ "${IDLE_FRESH_NO_RESTORE:-0}" == "1" ]] || {
    "${SSH[@]}" "for a in ${ADDRS[*]}; do devmem \$a 32; done" > "$OUT/poll.txt" 2>&1
    if ! grep -qi "deadbeef" "$OUT/poll.txt"; then
      RESTORED_AT=$ELAPSED
      break
    fi
  }
  if [[ $ELAPSED -ge $TIMEOUT_S ]]; then break; fi
  sleep 5
done

if [[ -z "$RESTORED_AT" ]]; then
  echo "poison still present after ${TIMEOUT_S}s"
  restore_originals
  echo "RESULT FAIL ARM did not rewrite the frame bank; a byte-exact match against"
  echo "       this bank cannot be distinguished from pre-existing DDR residue"
  exit 1
fi

echo "RESTORED_AFTER_S $RESTORED_AT (timeout was ${TIMEOUT_S}s)"

# The words healing is necessary but not sufficient: confirm the whole payload
# is byte-exact, not just the four words we touched.
if ! "$ROOT/tests/hw/test_idle_ddr_frame.sh" --bank "$BANK" > "$OUT/verify.log" 2>&1; then
  echo "RESULT FAIL poison healed but full-payload comparison failed:" >&2
  tail -5 "$OUT/verify.log" >&2
  exit 1
fi
grep -E "luma_mismatch_bytes|compared" "$OUT/verify.log" || true

echo "RESULT PASS ARM rewrote the poisoned bank within ${RESTORED_AT}s and the full"
echo "       payload is byte-exact, so the frame bank is a LIVE ARM write, not residue"
exit 0
