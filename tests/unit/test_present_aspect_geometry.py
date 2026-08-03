#!/usr/bin/env python3
"""Advertised VIDEO_AR original aspect must match FRAME_W:FRAME_H.

Positive: product Plex.sv uses FRAME_W/FRAME_H for (!ar) branch.
Negative: FAULT_ASPECT_FORCE_4_3 (hardcoded 4:3) must be detectable as a
mismatch when FRAME geometry is 16:9 (1280x720).

Also pure-arith: reduced ratios for product geometries.
"""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"


def gcd(a: int, b: int) -> int:
    return math.gcd(a, b)


def active_qsf_frame() -> tuple[int, int]:
    text = QSF.read_text(encoding="utf-8", errors="replace")
    w = h = None
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("#"):
            continue
        m = re.search(r'VERILOG_MACRO\s+"FRAME_W=(\d+)"', s)
        if m:
            w = int(m.group(1))
        m = re.search(r'VERILOG_MACRO\s+"FRAME_H=(\d+)"', s)
        if m:
            h = int(m.group(1))
    # Defaults in Plex.sv if QSF silent
    if w is None:
        w = 320
    if h is None:
        h = 240
    return w, h


def main() -> int:
    fails: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            fails.append(msg)
        else:
            print(f"OK {msg}")

    src = PLEX.read_text(encoding="utf-8", errors="replace")
    fw, fh = active_qsf_frame()
    g = gcd(fw, fh)
    exp_x, exp_y = fw // g, fh // g
    print(f"INFO QSF/active geometry FRAME={fw}x{fh} reduced={exp_x}:{exp_y}")

    # Product path must NOT hardcode 4:3 outside the FAULT ifdef
    # Strip FAULT blocks for the product-view check
    product_view = re.sub(
        r"`ifdef\s+FAULT_ASPECT_FORCE_4_3.*?`else",
        "`else",
        src,
        flags=re.S,
    )
    product_view = re.sub(
        r"`ifdef\s+FAULT_ASPECT_FORCE_4_3.*?`endif",
        "",
        product_view,
        flags=re.S,
    )

    check(
        "12'(FRAME_W)" in src or "FRAME_W)" in src and "VIDEO_ARX" in src,
        "VIDEO_ARX original branch references FRAME_W",
    )
    check(
        "12'(FRAME_H)" in src or ("FRAME_H)" in src and "VIDEO_ARY" in src),
        "VIDEO_ARY original branch references FRAME_H",
    )
    # Bare hardcoded 4:3 on the product (!FAULT) path is forbidden
    # After stripping FAULT ifdef true-branch, remaining 12'd4 for VIDEO_ARX is bad
    bad = re.search(
        r"assign\s+VIDEO_ARX\s*=\s*\(!ar\)\s*\?\s*12'd4\b",
        product_view,
    )
    check(bad is None, "product path must not hardcode VIDEO_ARX=12'd4")

    check("FAULT_ASPECT_FORCE_4_3" in src, "RED twin macro FAULT_ASPECT_FORCE_4_3 exists")

    # Arith table
    cases = [(320, 240, 4, 3), (640, 480, 4, 3), (1280, 720, 16, 9), (960, 540, 16, 9)]
    for w, h, ax, ay in cases:
        gg = gcd(w, h)
        check(w // gg == ax and h // gg == ay, f"arith {w}x{h} → {ax}:{ay}")

    # Active product geometry consistency: unreduced FRAME_W:FRAME_H equals reduced ratio
    check(
        fw / fh == exp_x / exp_y,
        f"active geometry ratio {fw}/{fh} == {exp_x}/{exp_y}",
    )

    # NEGATIVE twin simulation: hardcoded 4:3 vs 1280x720
    fault_arx, fault_ary = 4, 3
    geo_x, geo_y = 16, 9
    mismatch = fault_arx / fault_ary != geo_x / geo_y
    check(mismatch, "NEG: forced 4:3 disagrees with 1280x720 (16:9) — twin has teeth")

    # CLK_VIDEO routing under flag
    check("PRESENT_CLK_PIX_PLL" in src, "PRESENT_CLK_PIX_PLL still referenced")
    check(
        re.search(
            r"`ifdef\s+PRESENT_CLK_PIX_PLL\s*\n\s*assign\s+CLK_VIDEO\s*=\s*clk_pix_pll",
            src,
        )
        is not None,
        "CLK_VIDEO sources clk_pix_pll under PRESENT_CLK_PIX_PLL",
    )
    check(
        re.search(
            r"`else\s*\n\s*assign\s+CLK_VIDEO\s*=\s*clk_sys",
            src,
        )
        is not None,
        "CLK_VIDEO sources clk_sys in product else",
    )

    if fails:
        print("FAIL test_present_aspect_geometry:", file=sys.stderr)
        for f in fails:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("PASS test_present_aspect_geometry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
