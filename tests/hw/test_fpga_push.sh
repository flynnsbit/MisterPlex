#!/usr/bin/env bash
# Hardware: SPI push RGB565 into Plex frame_store; measure transfer time.
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

echo "=== ensure push_frame + test pattern ==="
if ! ssh_m 'test -x /media/fat/misterplex/bin/push_frame'; then
  echo "missing push_frame — deploy arm build first" >&2
  exit 1
fi
if ! ssh_m 'test -f /media/fat/plex_test_320x240.rgb565'; then
  python3 "$ROOT/scripts/gen_test_frame.py" /tmp/plex_test_320x240.rgb565
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no /tmp/plex_test_320x240.rgb565 \
    "$USER@$HOST:/media/fat/plex_test_320x240.rgb565"
fi

echo "=== SPI push ==="
OUT=$(ssh_m '/media/fat/misterplex/bin/push_frame --index 1 /media/fat/plex_test_320x240.rgb565')
echo "$OUT"
echo "$OUT" | grep -q 'OK'
# Optional: parse ms if present
if echo "$OUT" | grep -q 'ms'; then
  MS=$(echo "$OUT" | sed -n 's/.*(\([0-9.]*\) ms).*/\1/p')
  echo "push_ms=$MS"
  # Fail if absurdly slow (>2s) or failed parse
  python3 -c "import sys; ms=float('$MS' or 9999); sys.exit(0 if ms < 2000 else 1)"
fi

echo "=== second push (bank swap) ==="
ssh_m '/media/fat/misterplex/bin/push_frame --index 1 /media/fat/plex_test_320x240.rgb565' | grep -q OK

echo "test_fpga_push: OK on $HOST"
echo "NOTE: On CRT/HDMI, yellow border test pattern should appear (auto frame_store once has_frame)."
