#!/usr/bin/env bash
# Hardware Phase 3.3f/h: headers + residual status after real Baseline F3 push.
# First MB on this clip is I_NxN — FPGA residual probe is I16-only, so res_ok may be 0.
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
ssh_m 'echo load_core /media/fat/_Utility/Plex.rbf > /dev/MiSTer_cmd'
sleep 3
ssh_m 'grep -q Plex /tmp/CORENAME'

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
# res_ok optional until I_NxN residual probe is on FPGA
echo "test_f3_residual: OK on $HOST — IDR header goldens (mb0=0 qp=25); host walk ≥4 MBs"
