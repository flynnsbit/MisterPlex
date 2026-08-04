#!/usr/bin/env python3
"""Static checks for ddr_frame_base_mux (w-mem imports w-nostub/w-path module).

M10K=0 by construction (no memory arrays). DYN_BASE_EN=0 product-identical
select: fill = bank ? base_w1 : base_w0.
Negative: source must not hard-wire dyn when DYN_BASE_EN=0.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SV = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"


def main() -> int:
    print("=== test_ddr_frame_base_mux_static EXECUTED ===")
    text = SV.read_text(encoding="utf-8")
    fails = 0

    if "module ddr_frame_base_mux" not in text:
        print("FAIL missing module")
        fails += 1
    if re.search(r"\bram\s*\[", text) or "ramstyle" in text.lower():
        print("FAIL unexpected RAM (M10K must stay 0)")
        fails += 1
    if "parameter bit DYN_BASE_EN" not in text:
        print("FAIL missing DYN_BASE_EN")
        fails += 1
    # Product default path must assign fixed_base
    if "fill_bank_base = fixed_base" not in text and "assign fill_bank_base = fixed_base" not in text:
        # generate g_fixed form
        if "g_fixed" not in text or "fixed_base" not in text:
            print("FAIL missing fixed_base product path")
            fails += 1
    # Negative: g_fixed must force using_dyn=0
    if "using_dyn" not in text:
        print("FAIL missing using_dyn")
        fails += 1
    else:
        # In g_fixed block expect using_dyn = 0
        if not re.search(r"g_fixed[\s\S]*?using_dyn\s*=\s*1'b0", text):
            print("FAIL g_fixed must tie using_dyn=0 (neg: dyn leak)")
            fails += 1

    if fails:
        print(f"FAIL test_ddr_frame_base_mux_static fails={fails}")
        return 1
    print("PASS test_ddr_frame_base_mux_static M10K=0 DYN_BASE_EN default fixed")
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
