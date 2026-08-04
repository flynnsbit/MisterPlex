#!/usr/bin/env python3
"""720p pixel-clock + DDR bandwidth arithmetic (w-clock).

Product: shared pll_0002 outclk_3 @ 28.800000 MHz → exact 24.000 Hz @ H1600×V750.
VCO 720: C20=36, C90=8, Cpix=25. 29.7 illegal on shared VCO. 242 defect rejected.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def main() -> int:
    fails: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            fails.append(msg)
        else:
            print(f"OK {msg}")

    check(1650 * 750 * 60 == 74_250_000, "CEA VIC4 720p60")
    check(3300 * 750 * 24 == 59_400_000, "CEA VIC60 720p24")

    h, v = 1600, 750
    pix = h * v * 24
    check(pix == 28_800_000, f"product 1600*750*24={pix}")
    check(h * v == 1_200_000, "PIX_PER_FRAME=1200000")
    check(28_800_000 / (h * v) == 24.0, "fps_eff exact 24.000")

    # VCO 720 counter set
    check(720 / 20 == 36, "C20=36")
    check(720 / 90 == 8, "C90=8")
    check(720 / 28.8 == 25, "Cpix=25")
    check(50 * 72 / 5 == 720, "M=72 N=5 → VCO 720")
    check(50 / 5 == 10, "PFD=10 MHz")
    check(600 <= 720 <= 1600, "VCO 720 in range")
    check(1440 / 28.8 == 50, "alt VCO1440 Cpix=50")

    # 29.7 illegal shared
    check(180 * 33 == 5940, "29.7 shared min VCO 5940 OOR")
    check(29_700_000 != 28_800_000, "NEG: 29.7 != product 28.8")

    # blanking
    check(1600 - 1280 == 320, "H blank 320")
    check(750 - 720 == 30, "V blank 30")
    check((1390 - 1280) + 40 + (1600 - 1430) == 320, "sync window fits H1600")

    # retired 30/H1650 defect
    check(abs(30e6 / (1650 * 750) - 24.242424) < 1e-5, "retired 30@1650 = 24.242")

    pll = read(ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v")
    check('"28.800000 MHz"' in pll, "pll_0002 product 28.800000 MHz")
    check('"29.700000 MHz"' not in pll, "NEG: 29.7 absent from shared PLL")
    check("number_of_clocks(4)" in pll, "PRESENT_CLK_PIX_PLL branch 4 clocks")
    check("number_of_clocks(3)" in pll, "default 3 clocks")

    # no dedicated pll_pix
    check(not (ROOT / "fpga/Plex_MiSTer/rtl/pll_pix.v").exists(), "NEG: no pll_pix.v")
    check(not (ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_pix_0002.v").exists(), "NEG: no pll_pix_0002.v")
    qip = read(ROOT / "fpga/Plex_MiSTer/files.qip")
    check("pll_pix" not in qip, "NEG: files.qip has no pll_pix")

    plex = read(ROOT / "fpga/Plex_MiSTer/Plex.sv")
    check("outclk_3(clk_pix_pll)" in plex, "Plex.sv wires outclk_3")
    check("u_pll_pix" not in plex, "NEG: no dedicated u_pll_pix instance")
    check(".clk_pix(clk_pix_pll)" in plex, "integ clk_pix_pll")
    check(".clk_pix(clk_sys)" in plex, "default clk_sys")

    core = read(ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv")
    check(".H_TOTAL(1600)" in core, "present_core H_TOTAL=1600")
    check(".H_TOTAL(1650)" not in core, "NEG: present_core no H_TOTAL=1650")
    check(".H_SYNC_S(1390)" in core and ".H_SYNC_E(1430)" in core, "sync window 1390..1430")

    tim = read(ROOT / "fpga/Plex_MiSTer/rtl/present_video_timing_720p.sv")
    check("H_TOTAL_L  = 1600" in tim, "timing pack H=1600")
    check("PRODUCT_PIX_HZ = 28_800_000" in tim, "timing pack product 28.8")

    recipe = read(ROOT / "fpga/Plex_MiSTer/rtl/misterplex_clk_pix_recipe.svh")
    check("28_800_000" in recipe and "1600" in recipe, "recipe 28.8/H1600")
    check("720" in recipe and "C" in recipe, "recipe VCO720")

    sdc = read(ROOT / "fpga/Plex_MiSTer/Plex_clk_pix.sdc")
    check("general[3]" in sdc, "SDC shared general[3]")
    check("28.8" in sdc or "28.800" in sdc, "SDC documents 28.8")
    check("u_pll_pix" not in sdc, "NEG: SDC not dedicated pll_pix")
    check("get_clocks -nowarn" in sdc or "llength" in sdc, "SDC empty-clock guard")

    status = read(ROOT / "fpga/Plex_MiSTer/rtl/plex_clk_status.sv")
    check("FPS_PASS_LO = 239" in status and "FPS_PASS_HI = 241" in status, "PASS band [239,241]")
    check("H_TOTAL  = 1600" in status, "status default H=1600")

    # DDR BW unchanged
    check(1280 * 720 * 3 // 2 == 1_382_400, "I420 bytes")
    rd24 = 1_382_400 * 24 / 1e6
    check(abs(rd24 - 33.1776) < 1e-9, f"720p24 read {rd24}")
    check(20.0 * 2 >= 28.8, "PPC2 @20 feeds 28.8")
    check(20.0 < 28.8, "NEG: PPC1 @20 cannot feed 28.8")

    qsf = read(ROOT / "fpga/Plex_MiSTer/Plex.qsf")
    check(any("PRESENT_CLK_PIX_PLL" in ln and not ln.strip().startswith("#")
              for ln in qsf.splitlines()), "QSF PLL macro active")
    check("28.800000" in qsf or "28.8" in qsf, "QSF documents 28.8")

    if fails:
        print("FAIL test_720p_clk_ddr_arith:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("PASS test_720p_clk_ddr_arith")
    return 0


if __name__ == "__main__":
    sys.exit(main())
