#!/usr/bin/env python3
"""PLL out0 string must track CLK_SYS_24 / default 20; header SoT present."""
from __future__ import annotations
import re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
PLL = ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v"
HDR = ROOT / "fpga/Plex_MiSTer/rtl/misterplex_clk_hz.svh"
STAT = ROOT / "fpga/Plex_MiSTer/rtl/plex_clk_status.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"

def main() -> int:
    fails = []
    pll, hdr, qsf, qip, plex = (p.read_text(errors="ignore") for p in (PLL, HDR, QSF, QIP, PLEX))
    if not STAT.is_file():
        fails.append("missing plex_clk_status.sv")
    if "MISTERPLEX_CLK_SYS_PLL_FREQ" not in pll:
        fails.append("pll missing SYS freq macro")
    if 'output_clock_frequency0(`MISTERPLEX_CLK_SYS_PLL_FREQ)' not in pll:
        fails.append("pll out0 must use MISTERPLEX_CLK_SYS_PLL_FREQ macro")
    if re.search(r'output_clock_frequency0\("20\.000000 MHz"\)', pll):
        fails.append("pll still hardcodes 20.000000 on out0 (use macro)")
    if "`define MISTERPLEX_CLK_SYS_HZ 20_000_000" not in hdr:
        fails.append("header default sys hz missing")
    if "CLK_SYS_24" not in hdr or "24_000_000" not in hdr:
        fails.append("header missing CLK_SYS_24 arm")
    if "1650" not in hdr or "1312" not in hdr:
        fails.append("header missing CEA/L4 totals")
    # QSF default-OFF
    active = re.findall(r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"', qsf, re.M)
    for m in active:
        if m.startswith("CLK_SYS_24"):
            fails.append(f"CLK_SYS_24 active in product QSF: {m}")
    if not any("CLK_SYS_24" in ln and ln.strip().startswith("#") for ln in qsf.splitlines()):
        fails.append("QSF missing commented CLK_SYS_24 recipe")
    if "rtl/plex_clk_status.sv" not in qip:
        fails.append("plex_clk_status not in files.qip")
    if "u_plex_clk_status" not in plex:
        fails.append("Plex.sv missing u_plex_clk_status")
    # Arith
    if 1650 * 750 * 24 != 29_700_000:
        fails.append("CEA arith broken")
    if 1312 * 762 * 24 != 23_993_856:
        fails.append(f"L4 arith broken {1312*762*24}")
    else:
        print("OK L4 1312*762*24 = 23993856")
    print("OK CEA 1650*750*24 = 29700000")
    if fails:
        print("FAIL test_clk_sys_pll_sot")
        for f in fails: print(" ", f)
        return 1
    print("PASS test_clk_sys_pll_sot")
    return 0
if __name__ == "__main__":
    sys.exit(main())
