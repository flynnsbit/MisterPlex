#!/usr/bin/env bash
# Analog mux SDC: ce_pix is a clk_sys clock-enable. 15.6 kHz is H-rate, not STA.
# HDMI LCD refuse 15 kHz must stay GREEN (do not weaken test_hdmi_lcd_refuse_15k).
set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDC="$ROOT/fpga/Plex_MiSTer/Plex_analog_mux.sdc"
PLEX_SDC="$ROOT/fpga/Plex_MiSTer/Plex.sdc"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
MUX="$ROOT/fpga/Plex_MiSTer/rtl/analog_raster_mux.sv"
HDR="$ROOT/host/libmisterplex/display_raster.hpp"
CXX="${CXX:-g++}"
fails=0

fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

[ -f "$SDC" ] || { echo "missing $SDC" >&2; exit 1; }
[ -f "$PLEX_SDC" ] || { echo "missing $PLEX_SDC" >&2; exit 1; }
[ -f "$MUX" ] || { echo "missing $MUX" >&2; exit 1; }

grep -q 'SDC_FILE Plex_analog_mux.sdc' "$QIP" \
  || fail "files.qip must source Plex_analog_mux.sdc for a future sole fit"

if grep -nE '^[[:space:]]*create_generated_clock\b' "$SDC" "$PLEX_SDC"; then
  fail "product SDC has create_generated_clock (ce_pix/HSync must not become a clock)"
else
  ok "no create_generated_clock in Plex.sdc / Plex_analog_mux.sdc"
fi
if grep -nE '^[[:space:]]*derive_clocks\b' "$SDC" "$PLEX_SDC"; then
  fail "product SDC has derive_clocks (would invent clocks on analog enables)"
else
  ok "no derive_clocks in product analog/core SDC"
fi

grep -qi 'clock-enable' "$SDC" || fail "Plex_analog_mux.sdc must name ce_pix a clock-enable"
grep -q '20e6/1276' "$SDC" || fail "analog H-rate 20e6/1276 missing from SDC notes"
if grep -E '^[[:space:]]*set_false_path' "$SDC" | grep -q 'sel_lat'; then
  ok "set_false_path -to sel_lat (reset-latch analog_sel, not live F12)"
else
  fail "Plex_analog_mux.sdc missing set_false_path to sel_lat"
fi
if grep -E '^[[:space:]]*set_false_path' "$SDC" | grep -q -- '-from'; then
  fail "do not false_path FROM sel_lat (scandouble→ce_pix is real clk_sys)"
else
  ok "false_path is -to sel_lat only"
fi
if grep -E '^[[:space:]]*set_multicycle_path' "$SDC"; then
  fail "no multicycle on ce_pix-gated analog paths"
else
  ok "no set_multicycle_path in analog mux SDC"
fi

# Product path is reset-only. sel_lat on fstart is the LIVE_LATCH RED twin only.
mux_prod=$(awk '
  /`ifdef ANALOG_RASTER_FAULT_LIVE_LATCH/ {skip=1; next}
  skip && /`endif/ {skip=0; next}
  !skip {print}
' "$MUX")
if printf '%s\n' "$mux_prod" | grep -A40 'else if (fstart)' | grep -q 'sel_lat[[:space:]]*<='; then
  fail "sel_lat hops on frame_start (must be reset-only)"
else
  ok "sel_lat is not assigned on frame_start"
fi
if grep -A20 'ANALOG_RASTER_FAULT_LIVE_LATCH' "$MUX" | grep -q 'sel_lat[[:space:]]*<='; then
  ok "RED twin: LIVE_LATCH fstart hop is ifdef-gated"
else
  fail "ANALOG_RASTER_FAULT_LIVE_LATCH must still live-latch sel_lat (RED twin)"
fi
grep -q 'sel_lat[[:space:]]*<=[[:space:]]*sel_eff' "$MUX" \
  || fail "sel_lat reset load missing"

# HDMI LCD 15 kHz refuse must stay GREEN — do not touch the twin.
grep -q 'videoModeCmdIsHdmiLcdSafe' "$HDR" \
  || fail "do not drop videoModeCmdIsHdmiLcdSafe"
grep -q 'kVideoModeCmd240p = "video_mode 320,16,32,48,240,4,3,15,6500"' "$HDR" \
  || fail "kVideoModeCmd240p 6500 CRT modeline must stay"
grep -q 'kHdmiLcdMinLineHz = 31000' "$HDR" || fail "kHdmiLcdMinLineHz"

mkdir -p "$ROOT/build"
REFUSE="$ROOT/build/test_hdmi_lcd_refuse_15k"
if ! "$CXX" -std=c++17 -Wall -Wextra -I"$ROOT/host" -o "$REFUSE" \
     "$ROOT/tests/unit/test_hdmi_lcd_refuse_15k.cpp"; then
  fail "compile test_hdmi_lcd_refuse_15k"
else
  set +e
  REFUSE_OUT="$("$REFUSE" 2>&1)"
  REFUSE_RC=$?
  set -e
  printf '%s\n' "$REFUSE_OUT"
  if [ "$REFUSE_RC" -eq 0 ] && grep -q 'test_hdmi_lcd_refuse_15k: OK' <<<"$REFUSE_OUT"; then
    ok "test_hdmi_lcd_refuse_15k GREEN true rc=$REFUSE_RC"
  else
    fail "test_hdmi_lcd_refuse_15k expected rc=0 OK, got rc=$REFUSE_RC"
  fi
fi

# Red: an active generated clock on ce_pix must be visible as a product-SDC violation.
RED_SDC="$ROOT/build/analog_mux_ce_pix_genclk.sdc"
cat >"$RED_SDC" <<'SDC'
create_generated_clock -name ce_pix_analog -source [get_pins {*|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -divide_by 2 [get_keepers {*ce_pix*}]
SDC
if grep -nE '^[[:space:]]*create_generated_clock\b' "$RED_SDC" >/dev/null; then
  ok "RED twin: create_generated_clock on ce_pix is a detectable SDC violation"
else
  fail "RED twin grep did not see create_generated_clock"
fi

EXCL="$ROOT/scripts/check_timing_exclusions.py"
if [ -x "$EXCL" ] || [ -f "$EXCL" ]; then
  set +e
  EXCL_OUT="$(python3 "$EXCL" 2>&1)"
  EXCL_RC=$?
  set -e
  if [ "$EXCL_RC" -eq 0 ]; then
    ok "timing-exclusion gate includes analog mux SDC true rc=$EXCL_RC"
  else
    printf '%s\n' "$EXCL_OUT" >&2
    fail "timing-exclusion gate rc=$EXCL_RC (add sel_lat false_path fingerprint to baseline)"
  fi
fi

if [ "$fails" -ne 0 ]; then
  echo "test_analog_mux_sdc: $fails failure(s)" >&2
  exit 1
fi
echo "test_analog_mux_sdc: OK"
exit 0
