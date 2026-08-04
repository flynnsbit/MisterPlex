#!/usr/bin/env bash
# Parent-only device check: prove refresh is ~24 Hz, not the 16.16 Hz same-clock trap.
#
# Agents do NOT run this against hardware. Parent runs after deploy of a
# PRESENT_CLK_PIX_PLL + MULTI candidate RBF.
#
# Two independent controls (run both when possible):
#   A) Fabric status telem (PRODUCT_NO_STUB): raw[14]=fps_x10, raw[15]=flags
#   B) Host HDMI timed capture via scripts/hdmi_measure_refresh.py
#
# PASS A: fps_x10 in [230,250] (23.0–25.0) AND flags bit0=1 (window valid)
#         bit2=1 (fps_ok) bit1=1 (pix_ok) bit3=1 (pll_on compile)
# FAIL A: fps_x10 in [150,170] → classic 16.16 Hz trap (clk_pix still ~20 MHz glass)
#
# Exact parent commands:
#   1) Wait ≥2 s after core load (measure window = 1 s of clk_sys).
#   2) On MiSTer (or host UIO):  set_status --raw
#      Expect line: clk_pix_meas ... fps_x10=240 ... verdict=PASS_24HZ_BAND
#   3) Optional HDMI: python3 scripts/hdmi_measure_refresh.py --seconds 2
#      PASS median fps in [23.0, 25.5]; FAIL trap [15.5, 17.0]
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISTER_HOST="${MISTER_HOST:-192.168.1.183}"
MISTER_PASS="${MISTER_PASS:-1}"
WAIT_S="${WAIT_S:-3}"
SET_STATUS_REMOTE="${SET_STATUS_REMOTE:-/media/fat/linux/set_status}"

echo "=== check_clk_pix_refresh (parent device) ==="
echo "LAYOUT PRODUCT_NO_STUB: raw[14]=fps_x10 (~240 PASS, ~161=16.16 trap)"
echo "                         raw[15]=flags {0:valid,1:pix_ok,2:fps_ok,3:pll_on}"
echo "Control A: set_status --raw  |  Control B: hdmi_measure_refresh.py"

run_set_status_raw() {
  if [[ -x "$ROOT/build/set_status" ]]; then
    "$ROOT/build/set_status" --raw
    return $?
  fi
  if command -v set_status >/dev/null 2>&1; then
    set_status --raw
    return $?
  fi
  sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    root@"$MISTER_HOST" "sleep ${WAIT_S}; if [ -x ${SET_STATUS_REMOTE} ]; then ${SET_STATUS_REMOTE} --raw; elif command -v set_status >/dev/null 2>&1; then set_status --raw; else echo NO_STATUS_DUMP_TOOL; echo MANUAL_LAYOUT raw[14]=fps_x10 raw[15]=flags; ls -la /media/fat/linux/set_status 2>/dev/null || true; fi"
}

echo "--- A) fabric status (set_status --raw) ---"
set +e
OUT=$(run_set_status_raw 2>&1)
RC=$?
set -e
printf '%s\n' "$OUT"
echo "set_status_raw true rc=$RC"

FPS_LINE=$(printf '%s\n' "$OUT" | grep -E 'clk_pix_meas raw\[14\]=fps_x10=' | tail -1 || true)
VERDICT=$(printf '%s\n' "$OUT" | grep -E 'clk_pix_meas_verdict=' | tail -1 || true)
if [[ -n "$VERDICT" ]]; then
  echo "A_VERDICT_LINE=$VERDICT"
  if echo "$VERDICT" | grep -q PASS_24HZ_BAND; then
    echo "A_RESULT=PASS"
  elif echo "$VERDICT" | grep -q FAIL_16HZ_TRAP; then
    echo "A_RESULT=FAIL_TRAP"
  else
    echo "A_RESULT=UNKNOWN"
  fi
elif printf '%s\n' "$OUT" | grep -q NO_STATUS_DUMP_TOOL; then
  echo "A_RESULT=NO_TOOL — deploy tools/set_status to ${SET_STATUS_REMOTE} then re-run"
else
  RAWLINE=$(printf '%s\n' "$OUT" | grep -E '^raw:' | tail -1 || true)
  if [[ -n "$RAWLINE" ]]; then
    # fields: $1=raw: $2=b0 ... $16=b14 $17=b15
    B14=$(printf '%s\n' "$RAWLINE" | awk '{print $16}')
    B15=$(printf '%s\n' "$RAWLINE" | awk '{print $17}')
    if [[ -n "$B14" && -n "$B15" ]]; then
      FPS=$((16#$B14))
      FL=$((16#$B15))
      echo "PARSED fps_x10=$FPS flags=0x$B15"
      if (( FPS >= 230 && FPS <= 250 && (FL & 1) != 0 && (FL & 4) != 0 )); then
        echo "A_RESULT=PASS"
      elif (( FPS >= 150 && FPS <= 170 )); then
        echo "A_RESULT=FAIL_TRAP"
      else
        echo "A_RESULT=UNKNOWN"
      fi
    else
      echo "A_RESULT=UNKNOWN"
    fi
  else
    echo "A_RESULT=UNKNOWN"
  fi
fi
echo "FPS_LINE=${FPS_LINE:-none}"

echo "--- B) host HDMI timed refresh ---"
if [[ -f "$ROOT/scripts/hdmi_measure_refresh.py" ]]; then
  set +e
  python3 "$ROOT/scripts/hdmi_measure_refresh.py" --seconds 2
  echo "hdmi_measure true rc=$?"
  set -e
else
  echo "SKIP B: scripts/hdmi_measure_refresh.py missing"
fi

echo "ARTIFACT: paste A_RESULT + clk_pix_meas lines + hdmi fps"
echo "Claim 720p24 ONLY if A_RESULT=PASS or HDMI median in 23-25.5 (not 15.5-17 trap)"
exit 0
