#!/usr/bin/env bash
# Hardware Phase 3.3d: real Baseline → SPS + PPS + IDR slice_type=7 (I).
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ssh_m() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$USER@$HOST" "$@"
}

echo "=== reload Plex core (clean state) ==="
ssh_m 'echo load_core /media/fat/_Utility/Plex.rbf > /dev/MiSTer_cmd'
sleep 3
ssh_m 'grep -q Plex /tmp/CORENAME'

echo "=== real Baseline annex-B ==="
python3 "$ROOT/scripts/gen_test_annexb_real.py" /tmp/plex_real_baseline.h264
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no /tmp/plex_real_baseline.h264 \
  "$USER@$HOST:/media/fat/plex_real_baseline.h264"

echo "=== F3 push ==="
ssh_m '/media/fat/misterplex/bin/push_frame --index 3 /media/fat/plex_real_baseline.h264' | grep -q OK
sleep 0.5

read_status() {
  local st="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    st=$(ssh_m '/media/fat/misterplex/bin/push_frame --status' 2>/dev/null || true)
    if echo "$st" | grep -qE 'pps_valid=1|slice_type=7'; then
      echo "$st"
      return 0
    fi
    sleep 0.15
  done
  echo "$st"
  return 1
}

echo "=== status (sps+pps+slice_type=7 I-slice) ==="
ST=$(read_status) || true
echo "$ST"
echo "$ST" | grep -q 'sps_valid=1'
echo "$ST" | grep -q 'pps_valid=1'
echo "$ST" | grep -qE 'sps=320x240'
echo "$ST" | grep -q 'slice_type=7'
echo "$ST" | grep -q 'has_idr=1'
echo "$ST" | grep -q 'has_frame=1'

echo "test_f3_slice_hdr: OK on $HOST"
