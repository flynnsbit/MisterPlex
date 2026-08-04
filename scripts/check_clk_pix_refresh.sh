#!/usr/bin/env bash
# Parent-only: falsify 16.16 Hz trap vs product exact-24.000 vs shared-30 24.242.
# Do not run from agent worktrees against live hardware.
set -euo pipefail
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
MISTER_PASS="${MISTER_PASS:-1}"
SET_STATUS="${SET_STATUS:-/media/fat/linux/set_status}"

echo "PRODUCT: dedicated pll_pix=29.700000 MHz H1650×V750 → fps_eff=24.000 → fps_x10≈240"
echo "PASS [239,241]+raster_ok; FAIL_SHARED30 [242,244]; FAIL_TRAP [150,170]"
echo "ADV H1375×V900 must FAIL_RASTER. Stills cannot distinguish rates — use this."
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
elif printf '%s\n' "$OUT" | grep -q 'FAIL_SHARED30_TRAP'; then echo "A_RESULT=FAIL_SHARED30"
elif printf '%s\n' "$OUT" | grep -q 'FAIL_16HZ_TRAP'; then echo "A_RESULT=FAIL_16HZ_TRAP"
elif printf '%s\n' "$OUT" | grep -q 'FAIL_RASTER'; then echo "A_RESULT=FAIL_RASTER"
else echo "A_RESULT=UNKNOWN"
fi
echo "Claim 720p24 glass ONLY if A_RESULT=PASS (exact 24.000 product). Stills are blind."
