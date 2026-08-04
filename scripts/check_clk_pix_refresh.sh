#!/usr/bin/env bash
# Parent-only device check: prove refresh is ~24 Hz, not the 16.16 Hz same-clock trap.
#
# Agents do NOT run this against hardware. Parent runs after deploy of a
# PRESENT_CLK_PIX_PLL + MULTI candidate.
#
# Two independent controls (run both):
#   A) Fabric status telem (PRODUCT_NO_STUB): raw[14]=fps_x10, raw[15]=flags
#   B) Host HDMI timed capture via scripts/hdmi_measure_refresh.py (if grabber free)
#
# PASS A: fps_x10 in [230,250] (23.0–25.0) AND flags bit0=1 (window valid)
#         bit2=1 (fps_ok) bit1=1 (pix_ok) bit3=1 (pll_on compile)
# FAIL A: fps_x10 in [150,170] → classic 16.16 Hz trap (clk_pix still ~20 MHz glass)
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
MISTER_PASS="${MISTER_PASS:-1}"
WAIT_S="${WAIT_S:-3}"

echo "=== check_clk_pix_refresh (parent device) ==="
echo "PRE-REG: after >=1s of core run, status raw[14] (fps_x10) ~240 for 24 Hz"
echo "         16.16 Hz trap → ~161; pll_on flag bit3 should be 1 when macro built"

# --- A) SSH status dump via misterplexd helper or raw SPI tool if present ---
# Prefer a one-shot that already exists; fall back to documenting the byte map.
REMOTE_CMD='
set -e
# Wait for measure window
sleep '"$WAIT_S"'
# If misterplexd exposes status dump:
if [ -x /media/fat/linux/misterplexd ]; then
  # Best-effort: some builds log CoreStatus; else use dd of a debug node if added.
  true
fi
# Lab helper: read 16-byte status if mpx tool present
if command -v mpx-status >/dev/null 2>&1; then
  mpx-status --raw
elif [ -x /media/fat/linux/mpx_status_dump ]; then
  /media/fat/linux/mpx_status_dump
else
  echo "NO_STATUS_DUMP_TOOL"
  echo "MANUAL: use host FpgaSpi::getCoreStatus; raw[14]=fps_x10 raw[15]=flags"
  echo "LAYOUT_PRODUCT_NO_STUB: [119:112]=fps_x10 [127:120]=flags{valid,pix_ok,fps_ok,pll_on}"
fi
'

echo "--- A) fabric status (SSH) ---"
set +e
OUT=$(sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@"$MISTER_HOST" "$REMOTE_CMD" 2>&1)
RC=$?
set -e
printf '%s\n' "$OUT"
echo "ssh true rc=$RC"

# Parse fps if hex dump present
if printf '%s\n' "$OUT" | grep -qE 'raw\[14\]|fps_x10|NO_STATUS'; then
  echo "NOTE: interpret fps_x10: 240=24.0Hz PASS band; 161=16.1Hz FAIL trap"
fi

# --- B) Host HDMI measure (parent capture chain) ---
echo "--- B) host HDMI timed refresh (optional) ---"
if [[ -x "$ROOT/scripts/hdmi_measure_refresh.py" ]]; then
  set +e
  python3 "$ROOT/scripts/hdmi_measure_refresh.py" --seconds 2
  echo "hdmi_measure true rc=$?"
  set -e
else
  echo "SKIP B: scripts/hdmi_measure_refresh.py not present"
fi

echo "ARTIFACT: paste fps_x10 + flags + hdmi fps; claim 720p24 only if A or B shows ~24 not ~16"
exit 0
