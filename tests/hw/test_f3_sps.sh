#!/usr/bin/env bash
# Hardware Phase 3.3c: real Baseline annex-B → FPGA sps_parser → width/height status.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ssh_m() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$USER@$HOST" "$@"
}

echo "=== core is Plex ==="
ssh_m 'grep -q Plex /tmp/CORENAME'

echo "=== generate real Baseline 320x240 annex-B ==="
python3 "$ROOT/scripts/gen_test_annexb_real.py" /tmp/plex_real_baseline.h264
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no /tmp/plex_real_baseline.h264 \
  "$USER@$HOST:/media/fat/plex_real_baseline.h264"

echo "=== F3 push real stream ==="
OUT=$(ssh_m '/media/fat/misterplex/bin/push_frame --index 3 /media/fat/plex_real_baseline.h264')
echo "$OUT"
echo "$OUT" | grep -q OK
sleep 0.4

read_status() {
  local st="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    st=$(ssh_m '/media/fat/misterplex/bin/push_frame --status' 2>/dev/null || true)
    if echo "$st" | grep -qE 'sps_valid=1|sps=320x240'; then
      echo "$st"
      return 0
    fi
    sleep 0.15
  done
  echo "$st"
  return 1
}

echo "=== status (expect sps_valid=1 sps=320x240 has_idr stub_frames) ==="
ST=$(read_status) || true
echo "$ST"
echo "$ST" | grep -q 'has_stream=1'
echo "$ST" | grep -q 'sps_valid=1'
echo "$ST" | grep -qE 'sps=320x240'
echo "$ST" | grep -q 'has_idr=1'
SF=$(echo "$ST" | sed -n 's/.*stub_frames=\([0-9]*\).*/\1/p')
python3 -c "import sys; n=int('$SF' or 0); sys.exit(0 if n >= 1 else 1)"
echo "$ST" | grep -q 'has_frame=1'

echo "test_f3_sps: OK on $HOST — FPGA SPS parse $ST"
