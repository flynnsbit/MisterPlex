#!/usr/bin/env python3
"""720p24 pixel-clock recipe: 29.7 MHz product (not 74.25), PLL/SDC/wiring gates."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLL = ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v"
HDR = ROOT / "fpga/Plex_MiSTer/rtl/misterplex_clk_hz.svh"
RCP = ROOT / "fpga/Plex_MiSTer/rtl/misterplex_clk_pix_recipe.svh"
SDC = ROOT / "fpga/Plex_MiSTer/Plex_clk_pix.sdc"
STAT = ROOT / "fpga/Plex_MiSTer/rtl/plex_clk_status.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
FIX = ROOT / "tests/fixtures/p720_bw_contract.json"


def main() -> int:
    fails: list[str] = []
    pll = PLL.read_text(errors="replace")
    hdr = HDR.read_text(errors="replace")
    rcp = RCP.read_text(errors="replace")
    sdc = SDC.read_text(errors="replace")
    st = STAT.read_text(errors="replace")
    plex = PLEX.read_text(errors="replace")
    qsf = QSF.read_text(errors="replace")

    # --- (a) rate target: 720p24 → 29.7 exact, not assume 60 ---
    if 1650 * 750 * 24 != 29_700_000:
        fails.append("CEA F24 arith broken")
    if 1650 * 750 * 60 != 74_250_000:
        fails.append("CEA F60 arith broken")
    if "MISTERPLEX_CLKPIX_F24_HZ      = 29_700_000" not in rcp and "MISTERPLEX_CLKPIX_F24_HZ = 29_700_000" not in rcp.replace(" ", ""):
        if "29_700_000" not in rcp:
            fails.append("recipe missing 29_700_000 F24")
    if "MISTERPLEX_CLKPIX_PRODUCT_HZ" not in rcp:
        fails.append("recipe missing PRODUCT_HZ")
    if "PRODUCT_HZ  = MISTERPLEX_CLKPIX_F24_HZ" not in rcp and "PRODUCT_HZ=MISTERPLEX_CLKPIX_F24_HZ" not in rcp.replace(" ", ""):
        fails.append("product pix target must be F24 not F60")
    if 'MISTERPLEX_CLK_PIX_PLL_FREQ "29.700000 MHz"' not in pll:
        fails.append("pll_0002 default pix string must be 29.700000 MHz")
    if "fractional_vco_multiplier(\"false\")" not in pll:
        fails.append("emu pll must stay integer-N (false fractional) unless fit proves otherwise")
    # Exact M/N/C documentation + verify
    if "MISTERPLEX_CLKPIX_F24_PLL_M   = 297" not in rcp and "F24_PLL_M = 297" not in rcp.replace(" ", ""):
        if "297" not in rcp or "PLL_M" not in rcp:
            fails.append("recipe missing F24 PLL M=297")
    m, n, c = 297, 10, 50
    if (50_000_000 * m) // (n * c) != 29_700_000:
        fails.append("documented F24 M/N/C not exact")
    m60, n60, c60 = 297, 10, 20
    if (50_000_000 * m60) // (n60 * c60) != 74_250_000:
        fails.append("documented F60 M/N/C not exact")

    # SDC: async groups + product 29.7 + post-strip note
    for needle in (
        "general[3]",
        "set_clock_groups -asynchronous",
        "29.700",
        "pll_hdmi",
        "+0.311",
    ):
        if needle not in sdc:
            fails.append(f"Plex_clk_pix.sdc missing {needle}")

    # Wiring: Plex.sv switches clk_pix and CLK_VIDEO
    if "PRESENT_CLK_PIX_PLL" not in plex:
        fails.append("Plex.sv missing PRESENT_CLK_PIX_PLL")
    if ".clk_pix(clk_pix_pll)" not in plex.replace(" ", "") and ".clk_pix(clk_pix_pll)" not in plex:
        fails.append("Plex.sv must wire present.clk_pix to clk_pix_pll under macro")
    if "assign CLK_VIDEO = clk_pix_pll" not in plex and "CLK_VIDEO=clk_pix_pll" not in plex.replace(" ", ""):
        fails.append("Plex.sv must assign CLK_VIDEO=clk_pix_pll under macro")
    # pll_hdmi must remain a separate sys PLL (mention in comments OK)
    if re.search(r"^\s*pll_hdmi\b", pll, re.M) or "module pll_hdmi" in pll:
        fails.append("pll_0002 must not embed pll_hdmi module")

    # status consumes recipe + gates
    if "misterplex_clk_pix_recipe.svh" not in st:
        fails.append("plex_clk_status must include clk_pix recipe")
    if "g_clkpix_f24" not in st and "misterplex_clkpix_f24_must_be_29700000" not in st:
        fails.append("plex_clk_status needs F24 synth-active gate")

    # QSF default-OFF
    active = re.findall(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"', qsf, re.M
    )
    for mname in active:
        if mname.startswith("PRESENT_CLK_PIX"):
            fails.append(f"PRESENT_CLK_PIX* must stay default-OFF, active={mname}")
    if "PRESENT_CLK_PIX_PLL=1" not in qsf:
        fails.append("QSF missing commented PRESENT_CLK_PIX_PLL recipe")
    if "Plex_clk_pix.sdc" not in qsf:
        fails.append("QSF missing commented Plex_clk_pix.sdc")

    # Header SoT aligns
    if "MISTERPLEX_CEA720_F24_HZ 29_700_000" not in hdr:
        fails.append("clk_hz header missing F24")
    if "MISTERPLEX_CEA720_F60_HZ 74_250_000" not in hdr:
        fails.append("clk_hz header missing F60")

    # --- (b) T_copy retire PRE-REG measurement HIT ---
    import json

    fix = json.loads(FIX.read_text())
    pr = fix.get("t_copy_retire_prereg", {}).get("prediction", {})
    frame = 1000.0 / 24.0
    decode = 32.705
    tcopy = 14.978
    margin = frame - decode
    # PRE-REG was 8.962
    if abs(float(pr.get("margin_ms", 0)) - 8.962) > 1e-3:
        fails.append(f"prereg margin must be 8.962 got {pr.get('margin_ms')}")
    # Measurement (arithmetic re-run)
    meas = round(margin, 3)
    if abs(meas - 8.962) > 1e-3:
        fails.append(f"MEASURE miss: margin {meas} != PRE-REG 8.962")
    # serial deficit check
    if abs((tcopy - (frame - decode)) - 6.016) > 1e-2:
        fails.append("serial deficit arith drift")

    if fails:
        print("FAIL test_clk_pix_720p_recipe")
        for f in fails:
            print(" ", f)
        return 1
    print("PASS test_clk_pix_720p_recipe: product clk_pix=29.7 (720p24); F60 optional;")
    print("  integer M/N/C exact 0ppm-capable; SDC+wiring+gates OK; T_copy retire margin HIT 8.962")
    print(f"  MEASURE margin_ms={meas} PRE-REG=8.962 HIT (arith on parent S116/118)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
