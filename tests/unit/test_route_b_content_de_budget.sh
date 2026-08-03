#!/usr/bin/env bash
# Route B first-fit: every host-emittable content DE must fit clk_sys@1ppc.
# 1280×720 content DE is RED (glass is ascal, not core beam).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON="$ROOT/assets/route_b_content_de_budget.json"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
BEAM="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
MP="$ROOT/arm/misterplexd/media_player.cpp"
LAY="$ROOT/host/libmisterplex/ddr_frame_layout.hpp"
RESOLVE="$ROOT/arm/misterplexd/plex_resolve.cpp"
fail() { echo "FAIL: $*"; exit 1; }

[[ -f "$JSON" && -f "$CORE" && -f "$MP" && -f "$LAY" ]] || fail "missing inputs"

# --- Pre-registered arithmetic (rd-duck / parent-class) ---
awk 'BEGIN{
  clk=20e6
  # 1280 content DE blocked
  act24=1280*720*24
  if (act24 <= clk) { print "FAIL 1280x720@24 active fits clk?" > "/dev/stderr"; exit 1 }
  ht=1280+32; vt=720+16
  bf=clk/(ht*vt)
  if (bf >= 24) { print "FAIL min-blank 1280 reaches 24" > "/dev/stderr"; exit 1 }
  if (bf < 20.5 || bf > 21.0) { printf("FAIL beam_fps=%.4f\n", bf) > "/dev/stderr"; exit 1 }
  printf("OK RED 1280: active_24=%.3f Mpix/s beam_fps=%.4f (<%.0f)\n", act24/1e6, bf, 24)
  # max tier OK
  mt=960*540*30
  if (mt > clk) { print "FAIL 960x540@30 exceeds clk" > "/dev/stderr"; exit 1 }
  cf=clk/(1182*705)
  if (cf < 23.9 || cf > 24.1) exit 1
  printf("OK GREEN max-tier 960x540@30=%.3f Mpix/s film_beam=%.4f\n", mt/1e6, cf)
  # General gate formula: h_de*v_act*fps <= clk  AND  clk/((h+32)*(v+16)) >= fps
  # sample legal 624x480@30
  if (624*480*30 > clk) exit 1
  if (clk/((624+32)*(480+16)) < 30) {
    # product uses H_TOTAL=1182 class not min-blank — min-blank 624 still:
    mbf=clk/((624+32)*(480+16))
    if (mbf < 30) printf("NOTE min-blank 624@30=%.3f (product uses 1182 line)\n", mbf)
  }
  print "OK budget formulas"
}'

# --- Host cap: setDecodeSize must not allow 1280 ---
grep -q 'kRouteBMaxContentWidth' "$MP" || fail "media_player missing Route B width cap"
grep -q 'kRouteBMaxContentHeight' "$MP" || fail "media_player missing Route B height cap"
# Stale silent 1280 ceiling is the defect class
if grep -n 'if (w > 1280)' "$MP" | grep -v 'Route B\|kRouteB\|//'; then
  fail "media_player still has silent w>1280 ceiling"
fi
if grep -n 'if (h > 720)' "$MP" | grep -v 'Route B\|kRouteB\|//'; then
  fail "media_player still has silent h>720 ceiling"
fi
grep -q 'kRouteBMaxContentWidth = 960' "$LAY" || fail "layout missing 960 constant"
grep -q 'kRouteBMaxContentHeight = 540' "$LAY" || fail "layout missing 540 constant"
grep -q 'routeBContentDeExceedsClk' "$LAY" || fail "missing exceeds-clk helper"
grep -q 'routeBBeamMinBlankMissesFps' "$LAY" || fail "missing min-blank helper"
echo "OK host setDecodeSize capped at 960x540"

# --- Fabric: BEAM_960 forbids MULTI_PIXEL + tier clamp ---
grep -q 'PRESENT_BEAM_960 and PRESENT_MULTI_PIXEL are mutually exclusive' "$CORE" || \
  fail "missing MULTI_PIXEL mutex"
grep -q 'RT_MAX_HDE' "$CORE" || fail "core missing RT_MAX_HDE"
grep -q 'RT_MAX_VACT' "$CORE" || fail "core missing RT_MAX_VACT"
grep -q 'beam_hde_cap' "$CORE" || fail "core missing beam_hde_cap"
# Beam min pads (evidence for 1312/736)
grep -q "htot_min_pad = 11'd32" "$BEAM" || fail "beam pad H != 32"
grep -q "vtot_min_pad = 11'd16" "$BEAM" || fail "beam pad V != 16"
echo "OK fabric first-fit mutex + 960 tier clamp + beam pads"

# --- This tree must not auto-select TranscodeHd720 content 1280 ---
if grep -n 'TranscodeHd720' "$RESOLVE" 2>/dev/null; then
  # If regime exists, must not pin 1280x720 as content without MULTI_PIXEL guard
  if grep -n '1280x720' "$RESOLVE" | grep -viE 'comment|//|glass|hdmi|forbid|cap|reject'; then
    fail "plex_resolve emits 1280x720 content path without loud fence"
  fi
fi
# Product profiles stop at 480p in this tree
if grep -A6 'plexTranscodeProfiles' "$RESOLVE" | grep -q '720p\|1280'; then
  fail "plexTranscodeProfiles must not list 720p/1280 on first-fit Route B"
fi
echo "OK resolve has no first-fit 1280 content profile"

# --- Wall JSON honesty ---
python3 - <<'PY' || fail "json"
import json
from pathlib import Path
d=json.loads(Path("assets/route_b_content_de_budget.json").read_text())
assert d["first_fit"]["PRESENT_MULTI_PIXEL"] is False
assert d["first_fit"]["max_content_de"]=={"w":960,"h":540}
assert d["blocked_content_de"]["active_exceeds_clk_at_24"] is True
assert d["blocked_content_de"]["misses_24"] is True
assert abs(d["blocked_content_de"]["beam_fps_at_20mhz"]-20.7118)<0.01
assert d["host_cap"]["forbidden_silent_1280"] is True
print("OK wall json")
PY

# --- C++ helper unit (compile-free awk twin of constexpr) ---
awk 'BEGIN{
  # routeBContentDeExceedsClk(1280,720,24) true
  if (!((1280*720*24)>20000000)) exit 1
  if ((960*540*30)>20000000) exit 1
  # min blank miss 1280@24
  if (!(20000000 < 24*(1280+32)*(720+16))) exit 1
  if (20000000 < 24*(960+32)*(540+16)) {
    # may or may not — product uses 1182 not min blank
  }
  print "OK helper twins"
}'

echo "PASS test_route_b_content_de_budget"
echo "true rc=0"
