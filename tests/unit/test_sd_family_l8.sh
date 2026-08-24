#!/usr/bin/env bash
# L8 red twins for SD-family pairing / HDMI LCD 15 kHz refuse / gold pair_conf.
# Soft-skip is not a pass. Do not weaken if w-arm/w-fpga have not landed.
set -u
set -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAMED="$ROOT/scripts/misterplex_named_rbf.sh"
PAIR="$ROOT/scripts/misterplex_pair_conf.sh"
DR="$ROOT/host/libmisterplex/display_raster.hpp"
MP="$ROOT/arm/misterplexd/media_player.cpp"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "OK: $*"; }

GOLD_480P=07f54d9f8f0eda2fe75d9cc314f6de54
GOLD_240P=4d6efef954acf7b33747f35ac2878c1b
GOLD_480I=61db00e7d54efad7c1a456b127b798bd

# --- pair_conf gold 480p / 240p15 / 480i ------------------------------------
# shellcheck disable=SC1090
. "$PAIR"

assert_gold_pair_conf() {
  local sum="$1" label="$2"
  local tmp
  tmp=$(mktemp)
  printf 'PLEX_BASE=http://192.168.2.1:32400\nPLEX_TOKEN=keepme\nOSD_CONTROL=1\n' >"$tmp"
  misterplex_apply_pair_conf "$sum" "$tmp"
  grep -q 'PLEX_BASE=http://192.168.2.1:32400' "$tmp" || fail "$label clobbered PLEX_BASE"
  grep -q 'PLEX_TOKEN=keepme' "$tmp" || fail "$label clobbered PLEX_TOKEN"
  grep -q 'OSD_CONTROL=0' "$tmp" || fail "$label OSD_CONTROL=0"
  grep -q 'AV_PRESENT_LEAD_MS=40' "$tmp" || fail "$label lead 40"
  grep -q 'AV_RESYNC_DROP_MS=0' "$tmp" || fail "$label drop 0"
  if grep -q '^PLEX_BASE=' <<<"$(misterplex_pair_conf_keys "$sum")"; then
    fail "$label pair_conf_keys must not emit PLEX_BASE"
  fi
  rm -f "$tmp"
}

assert_gold_pair_conf "$GOLD_480P" "480p"
assert_gold_pair_conf "$GOLD_240P" "240p15"
assert_gold_pair_conf "$GOLD_480I" "480i"
ok "pair_conf gold OSD_CONTROL=0 lead 40 drop 0 PLEX_BASE untouched"

# --- HDMI LCD refuse ascal 15 kHz (6500 kHz) --------------------------------
# Live symbols: header predicate videoModeCmdIsHdmiLcdSafe / ForbiddenOnHdmiLcd;
# media_player applyDisplayRaster uses videoModeCmdForScoringPath(..., displaySink_)
# (never pokes kVideoModeCmd240p 6500 on HdmiLcd). Do not grep the retired
# media_player videoModeCmdIsHdmiLcdSafe call site.
CXX="${CXX:-g++}"
grep -q 'video_mode 320,16,32,48,240,4,3,15,6500' "$DR" || \
  fail "kVideoModeCmd240p must stay the 6500 kHz 15 kHz CRT modeline"
grep -q 'videoModeIsCrt15k' "$DR" || fail "display_raster missing videoModeIsCrt15k"
grep -q 'videoModeForbiddenOnHdmiLcd' "$DR" || \
  fail "HDMI LCD path missing videoModeForbiddenOnHdmiLcd"
grep -q 'videoModeCmdIsHdmiLcdSafe' "$DR" || \
  fail "HDMI LCD path missing videoModeCmdIsHdmiLcdSafe (must refuse kVideoModeCmd240p 6500)"
grep -q 'videoModeCmdForScoringPath' "$DR" || \
  fail "HDMI LCD scoring missing videoModeCmdForScoringPath"
if grep -q 'videoModeCmdForScoringPath(display.label, displaySink_)' "$MP"; then
  ok "applyDisplayRaster HDMI LCD uses videoModeCmdForScoringPath(..., displaySink_)"
else
  fail "applyDisplayRaster must refuse 15 kHz via videoModeCmdForScoringPath(..., displaySink_)"
fi

mkdir -p "$ROOT/build"
REFUSE_BIN="$ROOT/build/test_hdmi_lcd_refuse_15k"
if ! "$CXX" -std=c++17 -Wall -Wextra -I"$ROOT/host" -o "$REFUSE_BIN" \
     "$ROOT/tests/unit/test_hdmi_lcd_refuse_15k.cpp"; then
  fail "compile test_hdmi_lcd_refuse_15k"
else
  set +e
  REFUSE_OUT="$("$REFUSE_BIN" 2>&1)"
  REFUSE_RC=$?
  set +e
  printf '%s\n' "$REFUSE_OUT"
  echo "hdmi_lcd_refuse GREEN true rc=$REFUSE_RC"
  if [ "$REFUSE_RC" -eq 0 ] && grep -q 'test_hdmi_lcd_refuse_15k: OK' <<<"$REFUSE_OUT"; then
    ok "test_hdmi_lcd_refuse_15k GREEN"
  else
    fail "test_hdmi_lcd_refuse_15k expected rc=0 OK, got rc=$REFUSE_RC"
  fi
fi

# RED twin: plant-delete the refuse predicate, expect C++ twin fail, restore.
HDR_BAK=$(mktemp)
cp "$DR" "$HDR_BAK"
restore_hdr() { cp "$HDR_BAK" "$DR"; rm -f "$HDR_BAK"; }
trap restore_hdr EXIT
python3 - "$DR" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = """inline bool videoModeCmdIsHdmiLcdSafe(const char* cmd) {
    return cmd && cmd[0] && !videoModeForbiddenOnHdmiLcd(cmd);
}"""
new = """inline bool videoModeCmdIsHdmiLcdSafe(const char* cmd) {
    (void)cmd;
    return true; // PLANTED: refuse deleted
}"""
if old not in text:
    sys.exit("plant: videoModeCmdIsHdmiLcdSafe body not found")
p.write_text(text.replace(old, new, 1))
PY
if [ $? -ne 0 ]; then
  fail "plant HDMI refuse deletion"
else
  REFUSE_RED="$ROOT/build/test_hdmi_lcd_refuse_15k_planted"
  if ! "$CXX" -std=c++17 -Wall -Wextra -I"$ROOT/host" -o "$REFUSE_RED" \
       "$ROOT/tests/unit/test_hdmi_lcd_refuse_15k.cpp"; then
    fail "compile planted test_hdmi_lcd_refuse_15k"
  else
    set +e
    RED_OUT="$("$REFUSE_RED" 2>&1)"
    RED_RC=$?
    set +e
    printf '%s\n' "$RED_OUT"
    echo "hdmi_lcd_refuse RED planted-delete true rc=$RED_RC"
    if [ "$RED_RC" -eq 0 ]; then
      fail "planted refuse-delete unexpectedly passed"
    elif [ "$RED_RC" -eq 77 ]; then
      fail "planted refuse-delete rc=77 is skip not FAIL"
    else
      ok "RED: deleting videoModeCmdIsHdmiLcdSafe refuse fails twin (rc=$RED_RC)"
    fi
  fi
fi
restore_hdr
trap - EXIT
rm -f "$ROOT/build/test_hdmi_lcd_refuse_15k_planted"

# --- leftover PLXJ must not select 720p on SD-family live RBF ----------------
[ -f "$NAMED" ] || { echo "missing $NAMED" >&2; exit 1; }

setup_mock() {
  local mock="$1"
  rm -rf "$mock"
  mkdir -p "$mock/bin" "$mock/utility"
  : >"$mock/utility/Plex_480p.rbf"
  : >"$mock/utility/Plex_240p15.rbf"
  : >"$mock/utility/Plex_480i.rbf"
  : >"$mock/utility/Plex_720p24.rbf"
  cat >"$mock/bin/devmem" <<'EOF'
#!/bin/sh
addr=$(printf '%s' "$1" | tr 'A-F' 'a-f')
dir="${MPX_MOCK_DIR:?}"
t480="${dir}/t480_n"
case "$addr" in
  0x3047f130)
    echo 0x504C584A
    ;;
  0x3047f12c)
    echo 0x01010101
    ;;
  0x3007f128|0x300ff128)
    if [ "${MPX_MOCK_T480_CHANGING:-0}" = 1 ]; then
      n=0
      [ -f "$t480" ] && n=$(cat "$t480")
      n=$((n + 1))
      echo "$n" >"$t480"
      printf '0x%08x\n' "$n"
    else
      echo 0x02020202
    fi
    ;;
  *)
    echo 0x0
    ;;
esac
EOF
  chmod +x "$mock/bin/devmem"
}

run_named() {
  # $1 rbfname  $2 t480_changing  $3 echo_resolve|glass
  local rbfname="$1" t480="$2" what="$3"
  local mock
  mock=$(mktemp -d)
  setup_mock "$mock"
  printf '%s\n' "$rbfname" >"$mock/RBFNAME"
  (
    export MPX_MOCK_DIR="$mock"
    export MPX_MOCK_T480_CHANGING="$t480"
    export PATH="$mock/bin:$PATH"
    unset MPX_FORCE_LIVE_GLASS
    export MISTERPLEX_UTILITY="$mock/utility"
    export MISTERPLEX_LIVE_RBF="$mock/utility/Plex_480p.rbf"
    export RBFNAME_FILE="$mock/RBFNAME"
    # shellcheck disable=SC1090
    . "$NAMED"
    if [ "$what" = glass ]; then
      if live_glass_is_l4; then echo L4; else echo true480; fi
    else
      resolve_loaded_rbf
    fi
  )
  rm -rf "$mock"
}

assert_not_720() {
  local got="$1" msg="$2"
  case "$got" in
    *Plex_720p24*|*720p24*|*720p*)
      fail "$msg (got $got)"
      ;;
    *)
      ok "$msg (got $got)"
      ;;
  esac
}

got=$(run_named Plex_480p 0 resolve)
assert_not_720 "$got" "leftover PLXJ + RBFNAME=Plex_480p must not resolve 720p24"

got=$(run_named Plex_240p15 0 resolve)
assert_not_720 "$got" "leftover PLXJ + RBFNAME=Plex_240p15 must not resolve 720p24"

got=$(run_named Plex_480i 0 resolve)
assert_not_720 "$got" "leftover PLXJ + RBFNAME=Plex_480i must not resolve 720p24"

got=$(run_named Plex 0 resolve)
assert_not_720 "$got" "leftover PLXJ 504C584A + RBFNAME=Plex must not select 720p daemon"

glass=$(run_named Plex 0 glass)
if [ "$glass" = L4 ]; then
  fail "sticky leftover PLXJ 504C584A at 0x3047F130 must not report live_glass L4 (frozen PLXD)"
else
  ok "sticky leftover PLXJ is not live L4 (glass=$glass)"
fi

glass=$(run_named Plex 1 glass)
if [ "$glass" = L4 ]; then
  fail "leftover PLXJ must not report L4 when 480p PLXD is changing"
else
  ok "changing 480p PLXD beats leftover PLXJ (glass=$glass)"
fi

got=$(run_named Plex 1 resolve)
assert_not_720 "$got" "leftover PLXJ + changing 480p PLXD must not resolve 720p24"

if [ "$fails" -ne 0 ]; then
  echo "test_sd_family_l8: $fails failure(s)" >&2
  exit 1
fi
echo "test_sd_family_l8: OK"
exit 0
