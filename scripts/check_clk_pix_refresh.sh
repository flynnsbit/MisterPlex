#!/usr/bin/env bash
# Parent-only: falsify 16.16 Hz trap vs product 24.242 Hz (30 MHz H1650).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
MISTER_PASS="${MISTER_PASS:-1}"
WAIT_S="${WAIT_S:-3}"
SET_STATUS_REMOTE="${SET_STATUS_REMOTE:-/media/fat/linux/set_status}"

echo "=== check_clk_pix_refresh (parent device) ==="
echo "PRODUCT: clk_pix=30 MHz H1650×V750 → fps_eff=24.242 → fps_x10≈242"
echo "PASS [241,244]+raster_ok; ADV H1375xV900 must FAIL_RASTER  EXACT24 [238,240]  FAIL_TRAP [150,170]"
echo "LAYOUT: raw[14]=fps_x10  raw[15]=flags{valid,pix_ok,fps_ok,pll,trap,ce,de}"

run_raw() {
  if [[ -x "$ROOT/build/arm/set_status" ]]; then "$ROOT/build/arm/set_status" --raw; return $?; fi
  if command -v set_status >/dev/null 2>&1; then set_status --raw; return $?; fi
  sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    root@"$MISTER_HOST" "sleep ${WAIT_S}; if [ -x ${SET_STATUS_REMOTE} ]; then ${SET_STATUS_REMOTE} --raw; else echo NO_STATUS_DUMP_TOOL; fi"
}

set +e
OUT=$(run_raw 2>&1)
RC=$?
set -e
printf '%s\n' "$OUT"
echo "set_status_raw true rc=$RC"

if printf '%s\n' "$OUT" | grep -q 'PASS_242HZ_PRODUCT'; then echo "A_RESULT=PASS"
elif printf '%s\n' "$OUT" | grep -q 'FAIL_16HZ_TRAP'; then echo "A_RESULT=FAIL_TRAP"
elif printf '%s\n' "$OUT" | grep -q 'EXACT24_NOT_PRODUCT'; then echo "A_RESULT=EXACT24_NOT_PRODUCT"
else echo "A_RESULT=UNKNOWN — need set_status --raw after >=1s + 2 vsyncs"
fi
echo "Claim 720p24 glass ONLY if A_RESULT=PASS (24.242 product). Stills cannot tell rates apart."
exit 0
