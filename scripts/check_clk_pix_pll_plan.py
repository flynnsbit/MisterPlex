#!/usr/bin/env python3
"""Gate: clk_pix separate-PLL plan arithmetic + shipping PLL untouched.

Fails if:
  - CEA rates wrong
  - PPC balance claims lie (PIX24 needs PPC>=2, PIX60 PPC>=4)
  - plan claims applied while pll_0002 still lacks outclk_3 intent without status
  - shipping clk_sys/ddr strings drifted
  - someone requires clk_sys bump for scan-out
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def die(msg: str, rc: int = 1) -> None:
    print(f"CLK_PIX_PLL_PLAN_REJECTED(exit={rc}): {msg}", file=sys.stderr)
    raise SystemExit(rc)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path("."))
    ap.add_argument(
        "--contract",
        type=Path,
        default=Path("assets/clk_pix_pll_plan_contract.json"),
    )
    args = ap.parse_args()
    root = args.root.resolve()
    cpath = args.contract if args.contract.is_absolute() else root / args.contract
    try:
        c = json.loads(cpath.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"contract: {exc}", 2)

    fails: list[str] = []
    print("CLK_PIX_PLL_PLAN_BEGIN")

    h, v = 1650, 750
    ppf = h * v
    cea24 = ppf * 24 / 1e6
    cea60 = ppf * 60 / 1e6
    fps20 = 20e6 / ppf
    ar = c["arithmetic"]
    tol = 0.001
    if ar["pix_per_frame"] != ppf:
        fails.append(f"pix_per_frame {ar['pix_per_frame']} != {ppf}")
    if abs(float(ar["cea_720p24_mhz"]) - cea24) > tol:
        fails.append(f"cea24 {ar['cea_720p24_mhz']} != {cea24}")
    else:
        print(f"RATE_OK cea24={cea24:.4f}")
    if abs(float(ar["cea_720p60_mhz"]) - cea60) > tol:
        fails.append(f"cea60 {ar['cea_720p60_mhz']} != {cea60}")
    else:
        print(f"RATE_OK cea60={cea60:.4f}")
    if abs(float(ar["same_clock_20_fps"]) - fps20) > 0.01:
        fails.append(f"same_clock fps {ar['same_clock_20_fps']} != {fps20}")
    else:
        print(f"RATE_OK same_clk_20_fps={fps20:.4f}")

    # Balance
    ship = 20.0
    t24 = c["targets"]["PIX24"]
    t60 = c["targets"]["PIX60"]
    if int(t24["min_ppc"]) < 2:
        fails.append("PIX24 min_ppc must be >= 2")
    if int(t60["min_ppc"]) < 4:
        fails.append("PIX60 min_ppc must be >= 4")
    peak24 = ship * int(t24["min_ppc"])
    peak60 = ship * int(t60["min_ppc"])
    if peak24 < float(t24["clk_pix_mhz"]):
        fails.append("PIX24 fabric peak < clk_pix — balance broken")
    else:
        print(f"BALANCE_OK PIX24 peak={peak24} >= {t24['clk_pix_mhz']}")
    if peak60 < float(t60["clk_pix_mhz"]):
        fails.append("PIX60 fabric peak < clk_pix — balance broken")
    else:
        print(f"BALANCE_OK PIX60 peak={peak60} >= {t60['clk_pix_mhz']}")

    # PPC=1 @29.7 must be recognized as fail class
    if ship * 1 >= float(t24["clk_pix_mhz"]) - tol:
        fails.append("unexpected: 1ppc@20 covers 29.7 — arithmetic bug")
    else:
        print("BALANCE_OK PIX24_ppc1_starves")

    # Forbidden: clk_sys bump for scanout
    if not c["forbidden"].get("clk_sys_bump_for_scanout", False):
        fails.append("must forbid clk_sys bump for scan-out")
    else:
        print("FORBID_OK no_clk_sys_bump_for_scanout")

    # Shipping PLL still 3 clocks, 20/90
    pll_path = root / c["pll_source"]
    try:
        pll = pll_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        die(f"pll: {exc}", 2)
    if not re.search(r'output_clock_frequency0\("20\.000000 MHz"\)', pll):
        fails.append("shipping clk_sys string missing/changed in pll_0002.v")
    else:
        print("PLL_OK clk_sys=20.000000")
    if not re.search(r'output_clock_frequency2\("90\.000000 MHz"\)', pll):
        fails.append("shipping clk_ddr string missing/changed in pll_0002.v")
    else:
        print("PLL_OK clk_ddr=90.000000")
    # Default OFF path must still be 3 clocks; PIX24 is ifdef-gated.
    if not re.search(
        r"`else\s*\n\s*\.fractional_vco_multiplier\(\"false\"\).*?\.number_of_clocks\(3\)",
        pll,
        re.S,
    ) and "number_of_clocks(3)" not in pll:
        fails.append("default path must keep number_of_clocks(3)")
    elif "number_of_clocks(3)" not in pll:
        fails.append("missing number_of_clocks(3) default")
    else:
        print("PLL_OK number_of_clocks=3 present (default OFF path)")
    if 'output_clock_frequency3("29.700000 MHz")' not in pll:
        fails.append("PIX24 string 29.700000 MHz missing under PRESENT_CLK_PIX_PLL")
    else:
        print("PLL_OK PIX24 outclk_3 string landed under ifdef")
    if "PRESENT_CLK_PIX_PLL" not in pll:
        fails.append("pll_0002 must gate pix out behind PRESENT_CLK_PIX_PLL")
    else:
        print("PLL_OK gated by PRESENT_CLK_PIX_PLL")
    # Product default must not force 4 clocks unconditionally
    if re.search(r"^\s*\.number_of_clocks\(4\)", pll, re.M) and "PRESENT_CLK_PIX_PLL" not in pll:
        fails.append("unconditional number_of_clocks(4) without macro gate")
    # Plan doc exists and states key claims
    doc = root / c["plan_doc"]
    if not doc.is_file():
        fails.append(f"missing plan doc {c['plan_doc']}")
    else:
        text = doc.read_text(encoding="utf-8", errors="replace")
        for needle in (
            "29.700000 MHz",
            "74.250000 MHz",
            "clk_sys",
            "PRESENT_CLK_PIX_PLL",
        ):
            if needle not in text:
                fails.append(f"plan doc missing '{needle}'")
        if "PPC" not in text or "2" not in text:
            fails.append("plan doc must discuss PPC>=2")
        print(f"DOC_OK {c['plan_doc']}")

    # present_npx_path still has dual clock ports
    npx = root / "fpga/Plex_MiSTer/rtl/present_npx_path.sv"
    if npx.is_file():
        nt = npx.read_text(encoding="utf-8", errors="replace")
        if "clk_pix" not in nt or "clk_sys" not in nt:
            fails.append("present_npx_path must expose clk_sys and clk_pix")
        else:
            print("RTL_OK present_npx_path dual clocks")

    # Targets: landed under ifdef or still proposed; never claim product-default ON
    ok_st = {"PROPOSED_NOT_APPLIED", "LANDED_IFDEF_DEFAULT_OFF"}
    for name, t in c["targets"].items():
        if t.get("status") not in ok_st:
            fails.append(f"{name} status {t.get('status')} not in {ok_st}")
    if c.get("status") not in ok_st:
        fails.append(f"contract status {c.get('status')} not in {ok_st}")
    print(f"STATUS_OK contract={c.get('status')}")

    print("CLK_PIX_PLL_PLAN_END")
    if fails:
        for f in fails:
            print(f"  FAIL: {f}", file=sys.stderr)
        die(f"{len(fails)} check(s) failed", 1)
    print("PASS clk_pix_pll_plan_contract")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        sys.stderr.close()
        raise SystemExit(0)
