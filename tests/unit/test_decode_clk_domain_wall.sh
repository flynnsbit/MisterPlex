#!/usr/bin/env bash
# Decoder-domain PLL evaluation wall — evidence quotes, no applied bump.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON="$ROOT/assets/decode_clk_domain_wall.json"
PLL="$ROOT/fpga/Plex_MiSTer/rtl/pll/pll_0002.v"
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
SP="$ROOT/fpga/Plex_MiSTer/rtl/stream_path.sv"
CORE="$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
VERD="$ROOT/.agent-work/w-clock/DECODE_CLK_DOMAIN_VERDICT.md"
PRE="$ROOT/.agent-work/w-clock/DECODE_CLK_DOMAIN_PREREG.md"
fail() { echo "FAIL: $*"; exit 1; }

[[ -f "$JSON" && -f "$PLL" && -f "$PLEX" && -f "$SP" && -f "$VERD" && -f "$PRE" ]] || fail "missing inputs"

# --- Throughput arithmetic (parent table) ---
awk 'BEGIN{
  c20=20e6; c50=50e6
  mbs=39*30; fps=24; mb_s=mbs*fps
  b20=c20/mb_s; b50=c50/mb_s
  if (b20 < 712 || b20 > 713) { printf("FAIL b20=%.3f\n", b20) > "/dev/stderr"; exit 1 }
  if (b50 < 1780 || b50 > 1781.5) { printf("FAIL b50=%.3f\n", b50) > "/dev/stderr"; exit 1 }
  if (2200/b20 < 3.0 || 2200/b20 > 3.2) exit 1
  if (2200/b50 < 1.2 || 2200/b50 > 1.3) exit 1
  # 50 MHz alone still short
  if (b50 >= 2200) { print "FAIL 50MHz closes 2200?" > "/dev/stderr"; exit 1 }
  printf("OK budget 624@24 cy/MB @20=%.1f @50=%.1f short50=%.2fx\n", b20, b50, 2200/b50)
}'

# --- Decode on clk_sys 20 ---
grep -q 'output_clock_frequency0("20.000000 MHz")' "$PLL" || fail "PLL out0 not 20"
grep -q '\.outclk_0(clk_sys)' "$PLEX" || fail "Plex outclk_0 not clk_sys"
grep -q '\.clk(clk_sys)' "$PLEX" || fail "stream_path not on clk_sys"
# stream_path single clk into stub
grep -q 'input  wire        clk' "$SP" || fail "stream_path clk"
grep -q "output_clock_frequency2(\"90.000000 MHz\")" "$PLL" || fail "no clk_ddr 90"
grep -q 'output_clock_frequency4("0 MHz")' "$PLL" || fail "no spare out4@0"
echo "OK clocks: decode=clk_sys@20 ddr@90 spare out4"

# --- Must NOT have applied clk_dec bump ---
if grep -q 'output_clock_frequency4("50' "$PLL"; then
  fail "PLL out4 50 MHz applied without parent fit grant"
fi
if grep -qn 'clk_dec\|clk_decode' "$PLEX" "$SP" 2>/dev/null; then
  # allow comments in verdict only
  if grep -n 'clk_dec\|clk_decode' "$PLEX" "$SP" | grep -vE '^\s*//|comment'; then
    fail "clk_dec wired in product RTL without grant"
  fi
fi
echo "OK no applied clk_dec"

# --- Product fs_wr dark under DDR_FRAME_STORE ---
grep -q 'assign fs_wr_ready = 1'\''b1' "$CORE" || fail "DDR path missing fs_wr_ready tie"
# ddr_frame_store instance must not take wr_en in DDR branch — structural
if awk '/`ifdef DDR_FRAME_STORE/,/`else/' "$CORE" | grep -q '\.wr_en(fs_wr'; then
  fail "DDR branch must not map fs_wr_en into ddr_frame_store"
fi
echo "OK product fabric fs_wr does not feed ddr_frame_store"

# --- h264_decode_top not in fitted file list / not instantiated ---
if grep -q 'h264_decode_top.sv' "$QIP"; then
  fail "h264_decode_top unexpectedly in files.qip — update wall Fmax claim"
fi
if grep -n 'h264_decode_top' "$SP" "$PLEX" 2>/dev/null | grep -vE '^\s*//'; then
  fail "h264_decode_top instantiated — update Fmax unknown claim"
fi
echo "OK h264_decode_top not in product netlist (Fmax unknown)"

# --- Wall JSON honesty ---
python3 - <<'PY' || fail "json"
import json
from pathlib import Path
d=json.loads(Path("assets/decode_clk_domain_wall.json").read_text())
assert d["today"]["decode_mhz"]==20.0
assert d["today"]["dedicated_clk_decode"] is False
assert d["fmax_measured"]["stub_in_clk_sys_mhz"]==23.46
assert d["fmax_measured"]["nostub_clk_sys_mhz"]==32.59
assert d["fmax_measured"]["h264_decode_top_fmax_mhz"] is None
assert d["throughput"]["fifty_mhz_alone_closes_dominant_class"] is False
assert d["cdc"]["product_fabric_fs_wr_reaches_ddr_store"] is False
assert d["proposal_applied"] is False
assert d["verdict"].startswith("SEPARATE_DOMAIN")
print("OK wall json")
PY

# --- Verdict contains pre-register scorecard ---
grep -q 'P4 MISS' "$VERD" || fail "verdict missing P4 miss"
grep -q '42.333' "$VERD" || fail "verdict missing stub path delay quote"
grep -q 'Separate domain remains' "$VERD" || grep -q 'SEPARATE_DOMAIN' "$VERD" || \
  fail "verdict missing summary"

echo "PASS test_decode_clk_domain_wall"
echo "true rc=0"
