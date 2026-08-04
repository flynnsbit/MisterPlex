#!/usr/bin/env bash
# Parent-only: falsify 16.16 Hz trap vs 24 Hz refresh.
# Agents never run this against hardware.
#
# PASS: fps_x10 in [230,250] AND flags.valid AND flags.fps_ok
# FAIL trap: fps_x10 in [150,170]  (20e6/(1650*750) ≈ 16.16 → x10≈162)
#
# Exact commands:
#   ./scripts/check_clk_pix_refresh.sh
#   # or on MiSTer after ≥2s core uptime:
#   set_status --raw
#   python3 scripts/hdmi_measure_refresh.py --seconds 2
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
MISTER_PASS="${MISTER_PASS:-1}"
WAIT_S="${WAIT_S:-3}"
SET_STATUS_REMOTE="${SET_STATUS_REMOTE:-/media/fat/linux/set_status}"

echo "=== check_clk_pix_refresh (parent device) ==="
echo "LAYOUT PRODUCT_NO_STUB: raw[14]=fps_x10  raw[15]=flags{valid,pix_ok,fps_ok,pll_on,trap16}"
echo "PASS [230,250]  FAIL_TRAP [150,170]  arith: 29.7e6/1237500=24  20e6/1237500≈16.16"

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

if printf '%s\n' "$OUT" | grep -q 'PASS_24HZ_BAND'; then echo "A_RESULT=PASS"
elif printf '%s\n' "$OUT" | grep -q 'FAIL_16HZ_TRAP'; then echo "A_RESULT=FAIL_TRAP"
else echo "A_RESULT=UNKNOWN — need set_status --raw after >=1s"
fi

if [[ -f "$ROOT/scripts/hdmi_measure_refresh.py" ]]; then
  set +e
  python3 "$ROOT/scripts/hdmi_measure_refresh.py" --seconds 2
  echo "hdmi_measure true rc=$?"
  set -e
fi
echo "Claim 720p24 ONLY if A_RESULT=PASS (or HDMI 23-25.5), never on geometry stills alone"
exit 0
