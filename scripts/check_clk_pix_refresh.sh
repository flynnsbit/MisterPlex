#!/usr/bin/env bash
# Parent-only: falsify ~16.67 Hz trap vs product exact-24.000 vs defect 242.
set -euo pipefail
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
MISTER_PASS="${MISTER_PASS:-1}"
SET_STATUS="${SET_STATUS:-/media/fat/linux/set_status}"

echo "PRODUCT: shared pll outclk_3=28.800000 MHz H1600×V750 → fps_eff=24.000 → fps_x10≈240"
echo "PASS [239,241]+raster_ok; FAIL_242 [242,244]; FAIL_TRAP [150,170]"
echo "Wait ≥2s after core load for measure window..."
sleep 2

OUT=""
if command -v sshpass >/dev/null 2>&1; then
  OUT=$(sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    root@"$MISTER_HOST" "$SET_STATUS --raw" 2>/dev/null || true)
else
  OUT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    root@"$MISTER_HOST" "$SET_STATUS --raw" 2>/dev/null || true)
fi
echo "$OUT"
if printf '%s\n' "$OUT" | grep -q 'PASS_240HZ_PRODUCT'; then echo "A_RESULT=PASS"
elif printf '%s\n' "$OUT" | grep -q 'FAIL_242_DEFECT'; then echo "A_RESULT=FAIL_242"
elif printf '%s\n' "$OUT" | grep -q 'FAIL_16HZ_TRAP'; then echo "A_RESULT=FAIL_16HZ_TRAP"
elif printf '%s\n' "$OUT" | grep -q 'FAIL_RASTER'; then echo "A_RESULT=FAIL_RASTER"
else echo "A_RESULT=UNKNOWN"
fi
echo "Claim 720p24 glass ONLY if A_RESULT=PASS (exact 24.000). Stills are blind."
