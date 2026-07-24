#!/usr/bin/env bash
# Hardware Phase 3.3f/h/j/k: headers + residual status after real Baseline F3 push.
# First MB is I_NxN — FPGA residual levels/runs expect res_ok=1 res_tc=8 res_t1=3 res_dc=-24.
# F3-only (no F1): decode_stub still paints has_frame; hybrid host_owns_fs not latched.
# Assert control plane (sps/pps/mb0/qp/frame) matches host golden after IDR marking fix.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ssh_m() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$USER@$HOST" "$@"
}

echo "=== reload Plex core ==="
# Free SPI lock held by misterplexd during F3 probe
ssh_m 'killall -9 misterplexd 2>/dev/null || true; echo load_core /media/fat/_Utility/Plex.rbf > /dev/MiSTer_cmd'
# Core load + UIO reappear can take several seconds on lab DE10
sleep 5
ssh_m 'grep -q Plex /tmp/CORENAME'
# Wait until push_frame can open status (UIO ready)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ssh_m '/media/fat/misterplex/bin/push_frame --status' 2>/dev/null | grep -q 'status'; then
    break
  fi
  sleep 0.5
done

python3 "$ROOT/scripts/gen_test_annexb_real.py" /tmp/plex_real_baseline.h264
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no /tmp/plex_real_baseline.h264 \
  "$USER@$HOST:/media/fat/plex_real_baseline.h264"

ssh_m '/media/fat/misterplex/bin/push_frame --index 3 /media/fat/plex_real_baseline.h264' | grep -q OK
sleep 0.5

ST=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  ST=$(ssh_m '/media/fat/misterplex/bin/push_frame --status' 2>/dev/null || true)
  if echo "$ST" | grep -qE 'mb0=0|qp=25'; then
    break
  fi
  sleep 0.15
done
echo "$ST"
echo "$ST" | grep -q 'sps_valid=1'
echo "$ST" | grep -q 'pps_valid=1'
echo "$ST" | grep -q 'mb0=0'
echo "$ST" | grep -q 'qp=25'
echo "$ST" | grep -q 'has_frame=1'
# I_NxN first residual (nC=0): real Baseline probe_tc=8 t1=3 coeff0=-24
echo "$ST" | grep -qE 'res_ok=1'
echo "$ST" | grep -qE 'res_tc=8'
echo "$ST" | grep -qE 'res_t1=3'
echo "$ST" | grep -qE 'res_dc=-24'
echo "test_f3_residual: OK on $HOST — mb0=0 qp=25 res_ok=1 res_tc=8 res_t1=3 res_dc=-24"
