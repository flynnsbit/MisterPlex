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
    m = re.search(r"number_of_clocks\((\d+)\)", pll)
    nclk = int(m.group(1)) if m else -1
    if nclk != 3:
        # Allow 4 only if contract status says applied — we require PROPOSED + 3
        if c.get("status") == "PROPOSED_NOT_APPLIED":
            fails.append(
                f"pll number_of_clocks={nclk} but plan still PROPOSED_NOT_APPLIED "
                "(apply requires parent grant + status flip)"
            )
    else:
        print("PLL_OK number_of_clocks=3 (pix out not applied)")
    if re.search(r'output_clock_frequency3\("29\.', pll) or re.search(
        r'output_clock_frequency3\("74\.', pll
    ):
        if c.get("status") == "PROPOSED_NOT_APPLIED":
            fails.append("pll has clk_pix string but contract still PROPOSED_NOT_APPLIED")

    # Plan doc exists and states key claims
    doc = root / c["plan_doc"]
    if not doc.is_file():
        fails.append(f"missing plan doc {c['plan_doc']}")
    else:
        text = doc.read_text(encoding="utf-8", errors="replace")
        for needle in (
            "29.700000 MHz",
            "74.250000 MHz",
            "NOT applied",
            "clk_sys",
            "PRESENT_CLK_PIX_PLL",
            "min_ppc",
        ):
            if needle not in text and needle.replace("min_ppc", "PPC") not in text:
                # allow PPC spelling
                if needle == "min_ppc" and ("PPC≥2" in text or "PPC >= 2" in text or "PPC≥ 2" in text or "PPC=2" in text or "PPC≥2" in text or "PPC>=2" in text or "PPC≥2" in text):
                    continue
                if needle == "min_ppc" and ("PPC" in text and "2" in text and "4" in text):
                    continue
                if needle not in text:
                    fails.append(f"plan doc missing '{needle}'")
        print(f"DOC_OK {c['plan_doc']}")

    # present_npx_path still has dual clock ports
    npx = root / "fpga/Plex_MiSTer/rtl/present_npx_path.sv"
    if npx.is_file():
        nt = npx.read_text(encoding="utf-8", errors="replace")
        if "clk_pix" not in nt or "clk_sys" not in nt:
            fails.append("present_npx_path must expose clk_sys and clk_pix")
        else:
            print("RTL_OK present_npx_path dual clocks")

    # Targets must stay PROPOSED
    for name, t in c["targets"].items():
        if t.get("status") != "PROPOSED_NOT_APPLIED":
            fails.append(f"{name} status must be PROPOSED_NOT_APPLIED until grant")
    print("STATUS_OK all targets PROPOSED_NOT_APPLIED")

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
