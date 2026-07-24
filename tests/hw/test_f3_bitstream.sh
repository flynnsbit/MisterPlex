#!/usr/bin/env bash
# Hardware: push annex-B synthetic stream to F3 bitstream_fifo (SPI index 3).
# Scanner runs on FPGA; we only assert SPI path succeeds until status readback exists.
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

echo "=== generate annex-B test blob ==="
python3 "$ROOT/scripts/gen_test_annexb.py" /tmp/plex_test_annexb.h264
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no /tmp/plex_test_annexb.h264 \
  "$USER@$HOST:/media/fat/plex_test_annexb.h264"

echo "=== F3 SPI push (index 3) ==="
OUT=$(ssh_m '/media/fat/misterplex/bin/push_frame --index 3 /media/fat/plex_test_annexb.h264')
echo "$OUT"
echo "$OUT" | grep -q 'OK'
echo "$OUT" | grep -q 'index=3'

echo "=== second append push ==="
ssh_m '/media/fat/misterplex/bin/push_frame --index 3 /media/fat/plex_test_annexb.h264' | grep -q OK

echo "test_f3_bitstream: OK on $HOST"
echo "NOTE: LED_USER blinks fast when nalu_scanner has_stream; CRT eyes-on optional."
