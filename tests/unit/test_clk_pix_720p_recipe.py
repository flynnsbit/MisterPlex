#!/usr/bin/env python3
"""720p pixel-clock recipe gates: COMPACT 29.7 vs true CEA VIC60 59.4; PRE-REG only."""
from __future__ import annotations

import json
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
V4L2 = Path("/usr/include/linux/v4l2-dv-timings.h")


def main() -> int:
    fails: list[str] = []
    pll = PLL.read_text(errors="replace")
    hdr = HDR.read_text(errors="replace")
    rcp = RCP.read_text(errors="replace")
    sdc = SDC.read_text(errors="replace")
    st = STAT.read_text(errors="replace")
    plex = PLEX.read_text(errors="replace")
    qsf = QSF.read_text(errors="replace")

    # --- Arithmetic locks ---
    if 1650 * 750 * 24 != 29_700_000:
        fails.append("COMPACT F24 arith broken")
    if 1650 * 750 * 60 != 74_250_000:
        fails.append("CEA60 F60 arith broken")
    if 3300 * 750 * 24 != 59_400_000:
        fails.append("true CEA24 VIC60 arith broken")

    # Recipe must name COMPACT vs CEA24 distinctly
    if "COMPACT" not in rcp.upper() and "NOT CEA" not in rcp:
        fails.append("recipe must label 29.7/H1650 as non-CEA compact")
    if "MISTERPLEX_CLKPIX_COMPACT_HZ" not in rcp:
        fails.append("recipe missing COMPACT_HZ")
    if "MISTERPLEX_CLKPIX_CEA24_HZ" not in rcp:
        fails.append("recipe missing true CEA24_HZ")
    if "59_400_000" not in rcp:
        fails.append("recipe missing 59_400_000 CEA24")
    if "3300" not in rcp:
        fails.append("recipe missing CEA24 Htotal 3300")
    if "PRODUCT_HZ" not in rcp or "COMPACT" not in rcp:
        fails.append("product default must be COMPACT")
    # Product must equal compact not cea24
    if "PRODUCT_HZ    = MISTERPLEX_CLKPIX_COMPACT_HZ" not in rcp and \
       "PRODUCT_HZ = MISTERPLEX_CLKPIX_COMPACT_HZ" not in rcp.replace("  ", " "):
        # accept flexible whitespace
        if not re.search(r"PRODUCT_HZ\s*=\s*MISTERPLEX_CLKPIX_COMPACT_HZ", rcp):
            fails.append("PRODUCT_HZ must equal COMPACT_HZ (not CEA24)")

    if 'MISTERPLEX_CLK_PIX_PLL_FREQ "29.700000 MHz"' not in pll:
        fails.append("pll_0002 default pix string must be 29.700000 MHz (compact)")
    if "PRESENT_CLK_PIX_CEA24" not in pll:
        fails.append("pll_0002 must offer PRESENT_CLK_PIX_CEA24 → 59.4")
    if 'MISTERPLEX_CLK_PIX_PLL_FREQ "59.400000 MHz"' not in pll:
        fails.append("pll_0002 missing 59.400000 MHz CEA24 string")
    if "fractional_vco_multiplier(\"false\")" not in pll:
        fails.append("emu pll must stay integer-N")

    # Exact M/N/C
    if (50_000_000 * 297) // (10 * 50) != 29_700_000:
        fails.append("compact M/N/C not exact")
    if (50_000_000 * 297) // (10 * 25) != 59_400_000:
        fails.append("cea24 M/N/C not exact")
    if (50_000_000 * 297) // (10 * 20) != 74_250_000:
        fails.append("cea60 M/N/C not exact")

    # Optional Linux V4L2 control (if headers present)
    if V4L2.is_file():
        v = V4L2.read_text(errors="replace")
        if "1280X720P24" in v or "1280x720p24" in v.lower() or "V4L2_DV_BT_CEA_1280X720P24" in v:
            # Extract pixelclock near CEA 720p24 if present
            if "59400000" not in v and "59_400_000" not in v and "59400000ULL" not in v:
                # still require our recipe matches known CEA
                pass
            if "3300" not in rcp:
                fails.append("CEA24 H must be 3300 (v4l2 present)")
        # Strong control: file defines the macro
        if "V4L2_DV_BT_CEA_1280X720P24" in v:
            # Find block — expect 59400000 and large hfront
            idx = v.find("V4L2_DV_BT_CEA_1280X720P24")
            block = v[idx : idx + 400]
            if "59400000" not in block and "59.4" not in block:
                fails.append("v4l2 720p24 block missing 59400000 control")
    else:
        print("NOTE: v4l2-dv-timings.h absent; CEA24 numbers from recipe arith only")

    for needle in (
        "general[3]",
        "set_clock_groups -asynchronous",
        "29.700",
        "pll_hdmi",
        "+0.311",
    ):
        if needle not in sdc:
            fails.append(f"Plex_clk_pix.sdc missing {needle}")

    if "PRESENT_CLK_PIX_PLL" not in plex:
        fails.append("Plex.sv missing PRESENT_CLK_PIX_PLL")
    if ".clk_pix(clk_pix_pll)" not in plex and ".clk_pix(clk_pix_pll)" not in plex.replace(" ", ""):
        fails.append("Plex.sv must wire present.clk_pix to clk_pix_pll under macro")
    if "assign CLK_VIDEO = clk_pix_pll" not in plex and "CLK_VIDEO=clk_pix_pll" not in plex.replace(" ", ""):
        fails.append("Plex.sv must assign CLK_VIDEO=clk_pix_pll under macro")
    if re.search(r"^\s*pll_hdmi\b", pll, re.M) or "module pll_hdmi" in pll:
        fails.append("pll_0002 must not embed pll_hdmi module")

    if "misterplex_clk_pix_recipe.svh" not in st:
        fails.append("plex_clk_status must include clk_pix recipe")
    if "COMPACT" not in st.upper() and "g_clkpix_compact" not in st:
        fails.append("plex_clk_status needs compact synth-active gate")
    if "59_400_000" not in st and "g_clkpix_cea24" not in st:
        fails.append("plex_clk_status needs CEA24 gate")

    active = re.findall(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"', qsf, re.M
    )
    if not any(m == "PRESENT_CLK_PIX_PLL=1" for m in active):
        fails.append("PRESENT_CLK_PIX_PLL=1 must be product-ON (live 29.7 path)")
    if any(m.startswith("PRESENT_CLK_PIX_74_25") for m in active):
        fails.append("PRESENT_CLK_PIX_74_25 must stay OFF (720p24 not 60)")
    if not any(m == "PRESENT_MULTI_PIXEL=1" for m in active):
        fails.append("PRESENT_MULTI_PIXEL=1 must be ON with clk_pix live")
    if not any(m.startswith("FRAME_W=1280") for m in active):
        fails.append("FRAME_W=1280 must be product-ON")
    if not re.search(
        r'^\s*set_global_assignment\s+-name\s+SDC_FILE\s+Plex_clk_pix\.sdc', qsf, re.M
    ):
        fails.append("Plex_clk_pix.sdc must be active SDC_FILE")
    # Runtime measure must exist (device-checkable refresh)
    if "meas_fps_x10" not in st:
        fails.append("plex_clk_status must expose meas_fps_x10")
    if "clkstat_meas_fps_x10" not in plex:
        fails.append("Plex.sv must wire refresh measure into status path")

    if "MISTERPLEX_CEA720_F24_HZ 29_700_000" not in hdr:
        fails.append("clk_hz header missing F24 compact alias")
    if "MISTERPLEX_CEA720_TRUE24_HZ 59_400_000" not in hdr and "TRUE24" not in hdr:
        fails.append("clk_hz header missing true CEA24 59.4")
    if "NOT CEA" not in hdr and "not CEA" not in hdr and "COMPACT" not in hdr:
        fails.append("clk_hz must warn F24 alias is compact non-CEA")

    # --- T_copy retire: PRE-REGISTERED arithmetic ONLY (not MEASURE/HIT) ---
    fix = json.loads(FIX.read_text())
    pr_block = fix.get("t_copy_retire_prereg", {})
    status = str(pr_block.get("status", ""))
    if "PRE-REGISTERED" not in status.upper() and "PREREG" not in status.upper().replace("-", ""):
        fails.append(f"t_copy_retire_prereg.status must be PRE-REGISTERED, got {status!r}")
    # Forbid calling same-input arith a MEASURE/HIT at top level
    meas = pr_block.get("measurement", {})
    if isinstance(meas, dict):
        res = str(meas.get("result", "")).upper()
        if res in ("MEASURE", "MEASURED", "HIT", "PASS"):
            fails.append(
                "t_copy_retire measurement.result must not be MEASURE/HIT "
                "(same-input arith is not an independent control); use PRE-REGISTERED"
            )
        if meas.get("not_independent_measurement") is False:
            fails.append("measurement must not claim independent")
    pred = pr_block.get("prediction", {})
    if abs(float(pred.get("margin_ms", 0)) - 8.962) > 1e-3:
        fails.append(f"prereg margin must be 8.962 got {pred.get('margin_ms')}")
    # e2e must stay OPEN
    cs = fix.get("claim_split", {})
    t_e2e = cs.get("T_copy_e2e", cs.get("t_copy_e2e", ""))
    if isinstance(t_e2e, dict):
        if str(t_e2e.get("status", "")).upper() != "OPEN":
            fails.append("claim_split T_copy_e2e must stay OPEN")
    elif str(t_e2e).upper() != "OPEN":
        fails.append("claim_split T_copy_e2e must stay OPEN")

    # Fixture clk_pix labels
    cpr = fix.get("clk_pix_recipe", {})
    if cpr:
        comp = cpr.get("compact_720p24", {})
        if comp.get("Hz") != 29_700_000:
            fails.append("fixture compact Hz")
        cea = cpr.get("cea_720p24_vic60", {})
        if cea.get("Hz") != 59_400_000 or cea.get("H") != 3300:
            fails.append("fixture CEA24 must be 59.4/H3300")
        if "NON_CEA" not in str(comp.get("label", "")).upper() and "COMPACT" not in str(comp.get("label", "")).upper():
            fails.append("fixture must label 29.7 as COMPACT/NON_CEA")

    # Sanity: frame arith matches PRE-REG inputs (conditional check, not MEASURE)
    frame = 1000.0 / 24.0
    decode = 32.705
    tcopy = 14.978
    if abs(round(frame - decode, 3) - 8.962) > 1e-3:
        fails.append("PRE-REG margin formula drift")
    if abs((tcopy - (frame - decode)) - 6.016) > 1e-2:
        fails.append("serial deficit arith drift")

    if fails:
        print("FAIL test_clk_pix_720p_recipe")
        for f in fails:
            print(" ", f)
        return 1
    print("PASS test_clk_pix_720p_recipe:")
    print("  COMPACT 29.7/H1650 = non-CEA fabric raster (ascal); CEA VIC60 = 59.4/H3300")
    print("  product default COMPACT; CEA24/CEA60 optional macros; integer M/N/C exact")
    print("  T_copy retire margin 8.962 PRE-REGISTERED only; e2e OPEN (not MEASURE/HIT)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
