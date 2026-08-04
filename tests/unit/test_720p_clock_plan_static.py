#!/usr/bin/env python3
"""Static gates for 720p clock plan: default-OFF PLL, CLK_VIDEO, CEA arith, aspect."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLL = ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
SDC = ROOT / "fpga/Plex_MiSTer/Plex_clk_pix.sdc"
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
TIM720 = ROOT / "fpga/Plex_MiSTer/rtl/present_video_timing_720p.sv"


def main() -> int:
    fails: list[str] = []
    pll = PLL.read_text(errors="ignore")
    plex = PLEX.read_text(errors="ignore")
    qsf = QSF.read_text(errors="ignore")
    core = CORE.read_text(errors="ignore")
    tim = TIM720.read_text(errors="ignore")

    # --- CEA arithmetic (exact) ---
    h, v, fps = 1650, 750, 24
    need = h * v * fps
    if need != 29_700_000:
        fails.append(f"arith broken {need}")
    else:
        print(f"OK CEA pixclk 1650*750*24 = {need}")
    if "29.700000 MHz" not in pll and "29_700_000" not in pll:
        fails.append("pll missing 29.700000 MHz string under PRESENT_CLK_PIX_PLL")
    else:
        print("OK pll has 29.700000 MHz")

    # Product default still 20
    if not re.search(r'output_clock_frequency0\("20\.000000 MHz"\)', pll):
        fails.append("product clk_sys is not 20.000000 MHz")
    else:
        print("OK product clk_sys 20.000000 MHz")

    # out3 only under ifdef
    if "`ifdef PRESENT_CLK_PIX_PLL" not in pll:
        fails.append("pll missing PRESENT_CLK_PIX_PLL gate")
    # number_of_clocks(3) in else branch
    if ".number_of_clocks(3)" not in pll:
        fails.append("default PLL must keep number_of_clocks(3)")
    else:
        print("OK default number_of_clocks(3)")

    # QSF: macro and SDC must not be active
    active = re.findall(
        r'^\s*set_global_assignment\s+-name\s+(VERILOG_MACRO|SDC_FILE)\s+"?([^"\n]+)"?',
        qsf,
        flags=re.M,
    )
    for kind, val in active:
        if "PRESENT_CLK_PIX_PLL" in val or "Plex_clk_pix.sdc" in val:
            fails.append(f"DEFAULT_OFF violated active {kind}={val}")
    if not SDC.is_file():
        fails.append("missing Plex_clk_pix.sdc")
    else:
        sdc = SDC.read_text()
        if "set_clock_groups -asynchronous" not in sdc:
            fails.append("Plex_clk_pix.sdc missing async clock_groups")
        else:
            print("OK Plex_clk_pix.sdc async groups")
    if not any("PRESENT_CLK_PIX_PLL" in ln and ln.strip().startswith("#") for ln in qsf.splitlines()):
        fails.append("QSF missing commented PRESENT_CLK_PIX_PLL recipe")
    else:
        print("OK QSF commented PRESENT_CLK_PIX_PLL")

    # CLK_VIDEO routing
    if "PRESENT_CLK_PIX_PLL" not in plex or "CLK_VIDEO" not in plex:
        fails.append("Plex.sv missing CLK_VIDEO / pix gate")
    if not re.search(
        r"`ifdef PRESENT_CLK_PIX_PLL\s*\n\s*assign CLK_VIDEO = clk_pix_pll;",
        plex,
    ):
        fails.append("CLK_VIDEO must assign clk_pix_pll under PRESENT_CLK_PIX_PLL")
    else:
        print("OK CLK_VIDEO <- clk_pix_pll under flag")
    if not re.search(r"`else\s*\n\s*assign CLK_VIDEO = clk_sys;", plex):
        fails.append("CLK_VIDEO default must remain clk_sys")
    else:
        print("OK CLK_VIDEO default clk_sys")

    # Aspect tracks FRAME_W/H
    if "12'(`FRAME_W)" not in plex and "12'(`FRAME_W)" not in plex:
        if "VIDEO_ARX" in plex and "`FRAME_W" not in plex:
            fails.append("VIDEO_ARX must use FRAME_W for Original aspect")
    if "`FRAME_W" in plex and "`FRAME_H" in plex and "VIDEO_ARX" in plex:
        print("OK VIDEO_AR uses FRAME_W/H macros")
    else:
        fails.append("aspect macros missing")

    # Geometry vs aspect consistency gate: extract QSF FRAME and require AR path uses macros
    fw = re.search(r'VERILOG_MACRO\s+"FRAME_W=(\d+)"', qsf)
    fh = re.search(r'VERILOG_MACRO\s+"FRAME_H=(\d+)"', qsf)
    if not fw or not fh:
        fails.append("QSF missing FRAME_W/H")
    else:
        w, h = int(fw.group(1)), int(fh.group(1))
        print(f"OK QSF FRAME {w}x{h} aspect_ratio={w}:{h}")
        # Negative: hardcoded 4:3 without FRAME is forbidden
        if re.search(r"VIDEO_ARX = \(!ar\) \? 12'd4", plex):
            fails.append("hardcoded 4:3 VIDEO_ARX still present")
        else:
            print("OK no hardcoded 4:3 VIDEO_ARX")

    # MULTI CEA totals in core
    if ".H_TOTAL(1650)" not in core or ".V_TOTAL(750)" not in core:
        fails.append("MULTI beam must use CEA 1650x750")
    else:
        print("OK MULTI beam 1650x750")

    # Throughput documentation: PPC wall
    if "PRESENT_PX_PER_CLK=1" in qsf and "PRESENT_PX_PER_CLK=2" not in qsf:
        # recipe should prefer 2 now
        fails.append("QSF recipe should document PRESENT_PX_PER_CLK=2 for 29.7 feed")
    if "PRESENT_PX_PER_CLK=2" in qsf:
        print("OK QSF recipe PPC=2")

    # 720p timing module knows 29.7 threshold
    if "29_700_000" not in tim:
        fails.append("present_video_timing_720p missing 29.7 threshold")
    else:
        print("OK timing_720p 29.7 threshold")

    if fails:
        print("FAIL test_720p_clock_plan_static")
        for f in fails:
            print(" ", f)
        return 1
    print("PASS test_720p_clock_plan_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
