#!/usr/bin/env python3
"""720p pixel-clock + DDR bandwidth arithmetic (w-clock).

Locks:
  - CEA pack clocks (docs / MULTI path reference)
  - L4 content raster 1312x762 clock need (~24 MHz)
  - Product PLL SoT: clk_sys 20 default, PRESENT_CLK_SYS_24 → 24
  - DDR YUV420p read BW vs 90 MHz / 25% budget

No Quartus. No device. Exit 0 only when all asserts hold.
"""
from __future__ import annotations

import re
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

    # --- CEA pixel clocks (exact integers; MULTI / glass-native reference) ---
    h60, v60, fps60 = 1650, 750, 60
    pix60 = h60 * v60 * fps60
    check(pix60 == 74_250_000, f"CEA VIC4 720p60 f_pix={pix60} (==74250000)")

    h24v, v24v, fps24 = 3300, 750, 24
    pix24_vic = h24v * v24v * fps24
    check(pix24_vic == 59_400_000, f"CEA VIC60 720p24 f_pix={pix24_vic} (==59400000)")

    h_pack, v_pack = 1650, 750
    pix24_pack = h_pack * v_pack * 24
    check(pix24_pack == 29_700_000, f"pack 1650*750*24 f_pix={pix24_pack} (==29700000)")
    ppf = h_pack * v_pack
    check(ppf == 1_237_500, f"PIX_PER_FRAME pack={ppf}")

    # --- L4 product content raster (present_core PLEX_PRESENT_720P_L4) ---
    l4_h, l4_v = 1312, 762
    l4_cpf = l4_h * l4_v
    check(l4_cpf == 999_744, f"L4 clocks/frame={l4_cpf}")
    l4_need_24 = l4_cpf * 24
    check(l4_need_24 == 23_993_856, f"L4 exact-24Hz need={l4_need_24} Hz")
    active_only_24 = 1280 * 720 * 24
    check(active_only_24 == 22_118_400, f"active-only 1280*720*24={active_only_24}")
    check(active_only_24 > 20_000_000, "NEG: active-only already > clk_sys 20 MHz")
    check(l4_need_24 > 20_000_000, "NEG: L4 full raster > clk_sys 20 MHz")
    check(24_000_000 > l4_need_24, "clk_sys 24 MHz covers L4 exact-24 need")
    # fps at 20 and 24
    fps20 = 20_000_000 / l4_cpf
    fps24 = 24_000_000 / l4_cpf
    check(abs(fps20 - 20.005121) < 1e-5, f"L4 @20 MHz fps={fps20}")
    check(abs(fps24 - 24.006145) < 1e-5, f"L4 @24 MHz fps={fps24}")

    # NEGATIVE: active-only blanking is NOT a legal CEA pixel clock
    check(active_only_24 != 29_700_000, "NEG: active-only != 29.70 MHz pack")

    # --- Quote PLL SoT on disk ---
    pll = read(ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v")
    check('reference_clock_frequency("50.0 MHz")' in pll, "PLL ref=50.0 MHz")
    check('output_clock_frequency2("90.000000 MHz")' in pll, "PLL out2 clk_ddr=90.000000 MHz")
    check("PRESENT_CLK_SYS_24" in pll, "PLL has PRESENT_CLK_SYS_24 branch")
    check('"24.000000 MHz"' in pll, "PLL optional clk_sys 24.000000 MHz string")
    check('"20.000000 MHz"' in pll, "PLL default clk_sys 20.000000 MHz string")
    check("number_of_clocks(3)" in pll, "product number_of_clocks(3)")
    # No 4th fabric clock branch
    check("PRESENT_CLK_PIX_PLL" not in pll, "PLL has NO PRESENT_CLK_PIX_PLL (reverted)")
    check("output wire outclk_3" not in pll and "output wire  outclk_3" not in pll,
          "PLL has no outclk_3 port")
    # Default product expands to 20 via macro (not bare string on out0 when ifdef)
    check("MISTERPLEX_CLK_SYS_PLL_FREQ" in pll, "PLL uses MISTERPLEX_CLK_SYS_PLL_FREQ macro")

    qsf = read(ROOT / "fpga/Plex_MiSTer/Plex.qsf")
    active_sys24 = [
        ln
        for ln in qsf.splitlines()
        if "PRESENT_CLK_SYS_24" in ln and not ln.strip().startswith("#")
    ]
    check(not active_sys24, "QSF PRESENT_CLK_SYS_24 not active (default OFF)")
    active_pix = [
        ln
        for ln in qsf.splitlines()
        if "PRESENT_CLK_PIX_PLL" in ln and not ln.strip().startswith("#")
    ]
    check(not active_pix, "QSF PRESENT_CLK_PIX_PLL not active")
    check("PRESENT_CLK_SYS_24=1" in qsf, "QSF documents PRESENT_CLK_SYS_24 recipe")

    plex = read(ROOT / "fpga/Plex_MiSTer/Plex.sv")
    check("clk_pix_pll" not in plex, "Plex.sv has no clk_pix_pll (reverted)")
    check(".clk_pix(clk_sys)" in plex, "product .clk_pix(clk_sys)")
    check("assign CLK_VIDEO = clk_sys" in plex, "CLK_VIDEO=clk_sys")

    # Dead SDC must be gone
    sdc_path = ROOT / "fpga/Plex_MiSTer/Plex_clk_pix.sdc"
    check(not sdc_path.exists(), "Plex_clk_pix.sdc removed (dead path)")

    # present L4 totals still 1312x762
    core = read(ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv")
    check("L4_H_TOTAL_P = 1312" in core, "L4_H_TOTAL_P=1312")
    check("L4_V_TOTAL_P = 762" in core, "L4_V_TOTAL_P=762")

    # --- DDR bandwidth: product format is YUV420p / I420 ---
    layout = read(ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh")
    check("DDR_FRAME_720P_YUV420P_BYTES = 1382400" in layout, "I420 1280x720 bytes=1382400")
    check(1280 * 720 * 3 // 2 == 1_382_400, "I420 arith 1280*720*3/2")

    frame_b = 1_382_400
    rd24 = frame_b * 24 / 1e6
    rd60 = frame_b * 60 / 1e6
    check(abs(rd24 - 33.1776) < 1e-9, f"YUV420p 720p24 FPGA read={rd24} MB/s")
    check(abs(rd60 - 82.944) < 1e-9, f"YUV420p 720p60 FPGA read={rd60} MB/s")

    peak = 90.0 * 8.0
    budget = peak * 0.25
    check(peak == 720.0, f"DDR peak @90MHz={peak} MB/s")
    check(budget == 180.0, f"pessimistic FPGA-read budget={budget} MB/s")
    check(rd24 < budget, f"FIT: 24fps read {rd24} < budget {budget}")
    check(rd60 < budget, f"FIT: 60fps read {rd60} < budget {budget}")

    tot24 = 2 * rd24
    tot60 = 2 * rd60
    check(tot24 < peak, f"total fabric 24fps {tot24} < peak {peak}")
    check(tot60 < peak, f"total fabric 60fps {tot60} < peak {peak}")

    rgb_frame = 1280 * 720 * 2
    rgb60 = rgb_frame * 60 / 1e6
    check(rgb60 == 110.592, f"RGB565 720p60 read={rgb60}")
    old_budget_20 = 20.0 * 8.0 * 0.25
    check(old_budget_20 == 40.0, "old confused 20MHz*8*25% budget=40")
    check(rd60 > old_budget_20, "NEG: 720p60 YUV would FAIL if DDR were 20 MHz")

    # Throughput wall: PPC=1 @20 cannot feed CEA pack 29.7; L4 needs 24 not 29.7
    check(20.0 < 29.7, "NEG: clk_sys 20 MHz < 29.7 pack Mpix/s (MULTI)")
    check(20.0 < 23.993856, "NEG: clk_sys 20 MHz < L4 24fps need")
    check(24.0 >= 23.993856, "clk_sys 24 MHz >= L4 24fps need")

    if fails:
        print("FAIL test_720p_clk_ddr_arith:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("PASS test_720p_clk_ddr_arith")
    return 0


if __name__ == "__main__":
    sys.exit(main())
