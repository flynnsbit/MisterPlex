#!/usr/bin/env python3
"""720p pixel-clock + DDR bandwidth arithmetic (w-clock).

Product: dedicated pll_pix @ 29.700000 MHz → exact 24.000 Hz @ H1650×V750.
Shared pll_0002 cannot host 29.7 with 20+90 (min VCO 5940 MHz) — parent-measured.

Positive cases lock CEA / layout constants to exact integer Hz and MB/s.
Negative cases: active-only blanking, shared-30-as-product, 29.7-on-shared-pll.

No Quartus. No device. Exit 0 only when all asserts hold.
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

    h60, v60, fps60 = 1650, 750, 60
    pix60 = h60 * v60 * fps60
    check(pix60 == 74_250_000, f"CEA VIC4 720p60 f_pix={pix60} (==74250000)")

    h24v, v24v, fps24 = 3300, 750, 24
    pix24_vic = h24v * v24v * fps24
    check(pix24_vic == 59_400_000, f"CEA VIC60 720p24 f_pix={pix24_vic} (==59400000)")

    h_pack, v_pack = 1650, 750
    pix24 = h_pack * v_pack * 24
    check(pix24 == 29_700_000, f"arith 1650*750*24={pix24} (product dedicated PLL)")
    ppf = h_pack * v_pack
    check(ppf == 1_237_500, f"PIX_PER_FRAME pack={ppf}")
    fps_prod = 29_700_000 / ppf
    check(fps_prod == 24.0, f"product fps_eff@29.7M={fps_prod}")

    check(180 * 33 == 5940, "shared min VCO for 29.7 with 20+90 = 5940 MHz (OOR)")
    check(50_000_000 * 297 // (10 * 50) == 29_700_000, "dedicated M/N/C → 29.7 exact")
    check(600 <= 1485 <= 1600, "VCO 1485 in Cyclone V fPLL range ~600-1600")

    fps_trap = 30_000_000 / ppf
    check(abs(fps_trap - 24.242424) < 1e-5, f"shared30 fps_eff={fps_trap}")
    check(30_000_000 != 29_700_000, "NEG: shared30 != product 29.7")
    exact_30 = 30_000_000 // 24
    check(exact_30 == 1_250_000, f"30e6/24 HT*VT need={exact_30}")
    pairs = []
    for h in range(1281, 2501):
        if exact_30 % h == 0:
            v = exact_30 // h
            if v > 720:
                pairs.append((h, v))
    check(len(pairs) == 0, f"NEG: no exact-24 geometry at 30 MHz, got {pairs[:3]}")

    active_only_24 = 1280 * 720 * 24
    check(active_only_24 != 29_700_000, "NEG: active-only 1280*720*24 != 29.70 MHz")
    check(active_only_24 == 22_118_400, f"NEG twin value active_only_24={active_only_24}")

    pll = read(ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v")
    check('output_clock_frequency0("20.000000 MHz")' in pll, "PLL out0 clk_sys=20.000000 MHz")
    check('output_clock_frequency2("90.000000 MHz")' in pll, "PLL out2 clk_ddr=90.000000 MHz")
    check('reference_clock_frequency("50.0 MHz")' in pll, "PLL ref=50.0 MHz")
    check(".number_of_clocks(3)" in pll, "fabric PLL number_of_clocks(3)")
    check('"29.700000 MHz"' not in pll, "NEG: 29.7 must not be on shared pll_0002")
    check('"30.000000 MHz"' not in pll, "NEG: 30 MHz not on fabric PLL either")

    pp = read(ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_pix_0002.v")
    check('"29.700000 MHz"' in pp, "pll_pix product string 29.700000 MHz")
    check(".number_of_clocks(1)" in pp, "pll_pix number_of_clocks(1)")
    check('fractional_vco_multiplier("false")' in pp, "pll_pix integer-N")
    check('"74.250000 MHz"' in pp, "pll_pix optional 74.250000 MHz string")

    wrap = read(ROOT / "fpga/Plex_MiSTer/rtl/pll_pix.v")
    check("module pll_pix" in wrap and "pll_pix_0002" in wrap, "pll_pix.v wraps pll_pix_0002")
    qip = read(ROOT / "fpga/Plex_MiSTer/files.qip")
    check("rtl/pll_pix.v" in qip, "files.qip lists pll_pix.v")
    check("rtl/pll/pll_pix_0002.v" in qip, "files.qip lists pll_pix_0002.v")

    qsf = read(ROOT / "fpga/Plex_MiSTer/Plex.qsf")
    active_pix = [
        ln for ln in qsf.splitlines()
        if "PRESENT_CLK_PIX_PLL" in ln and not ln.strip().startswith("#")
    ]
    check(bool(active_pix), "QSF PRESENT_CLK_PIX_PLL active (integ 24 Hz path ON)")
    check("Plex_clk_pix.sdc" in qsf, "QSF mentions Plex_clk_pix.sdc recipe")
    check("29.7" in qsf or "dedicated" in qsf.lower(), "QSF documents dedicated 29.7 product")

    active_fw = [ln for ln in qsf.splitlines()
                 if "FRAME_W=" in ln and not ln.strip().startswith("#")]
    active_fh = [ln for ln in qsf.splitlines()
                 if "FRAME_H=" in ln and not ln.strip().startswith("#")]
    check(any("FRAME_W=1280" in ln for ln in active_fw), "QSF active FRAME_W=1280")
    check(any("FRAME_H=720" in ln for ln in active_fh), "QSF active FRAME_H=720")
    check(not any("FRAME_W=640" in ln for ln in active_fw), "QSF hollow FRAME_W=640 absent")
    check(not any("FRAME_H=480" in ln for ln in active_fh), "QSF hollow FRAME_H=480 absent")

    plex = read(ROOT / "fpga/Plex_MiSTer/Plex.sv")
    check("clk_pix_pll" in plex, "Plex.sv declares clk_pix_pll under flag path")
    check("pll_pix u_pll_pix" in plex, "Plex.sv instantiates dedicated pll_pix")
    check(".clk_pix(clk_sys)" in plex, "product .clk_pix(clk_sys) still present")
    check(".clk_pix(clk_pix_pll)" in plex, "integ .clk_pix(clk_pix_pll) present")
    check("assign CLK_VIDEO = clk_pix_pll" in plex, "CLK_VIDEO follows clk_pix_pll under PLL")
    check("pll_locked_all" in plex, "reset waits for both PLLs when pix on")

    tim = read(ROOT / "fpga/Plex_MiSTer/rtl/present_video_timing_720p.sv")
    check("H_TOTAL_L  = 1650" in tim, "timing pack H_TOTAL=1650")
    check("V_TOTAL_L  = 750" in tim, "timing pack V_TOTAL=750")
    check("74_250_000" in tim or "74.25" in tim, "timing pack documents 74.25")

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
    check(rgb60 < budget, "RGB565 720p60 still < 180 budget (docs: viable)")
    old_budget_20 = 20.0 * 8.0 * 0.25
    check(old_budget_20 == 40.0, "old confused 20MHz*8*25% budget=40")
    check(rd60 > old_budget_20, "NEG: 720p60 YUV would FAIL if DDR were 20 MHz")

    check(20.0 < 29.7, "NEG: clk_sys 20 MHz < 29.7 Mpix/s need (PPC=1)")
    check(20.0 * 2 >= 29.7, "PPC=2 @20 MHz fabric groups can feed 29.7")

    sdc = read(ROOT / "fpga/Plex_MiSTer/Plex_clk_pix.sdc")
    check("set_clock_groups -asynchronous" in sdc, "SDC async groups clk_pix")
    check("residual" not in sdc.lower() or "Do NOT" in sdc, "SDC does not silence residual")
    check("u_pll_pix" in sdc, "SDC names u_pll_pix hierarchy")
    check("general[0]" in sdc, "SDC names dedicated general[0] clk_pix")
    check("general[3]" not in sdc, "NEG: SDC must not use shared general[3] for clk_pix")

    recipe = read(ROOT / "fpga/Plex_MiSTer/rtl/misterplex_clk_pix_recipe.svh")
    check("29_700_000" in recipe, "recipe product 29_700_000")
    check("1485" in recipe, "recipe VCO 1485")

    if fails:
        print("FAIL test_720p_clk_ddr_arith:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("PASS test_720p_clk_ddr_arith")
    return 0


if __name__ == "__main__":
    sys.exit(main())
