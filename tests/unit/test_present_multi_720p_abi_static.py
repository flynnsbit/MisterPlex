#!/usr/bin/env python3
"""BLOCKING (rd-duck): MULTI+PPC2 must not inherit L4-only 720p DDR ABI gate.

FAIL if present_core still selects DDR_FRAME_720P_* only under
PLEX_PRESENT_720P_L4. PASS when shared ddr_frame_abi_select.svh binds by
FRAME 1280×720 (L4 or MULTI). Also require MULTI QSF recipe to name
FRAME_W=1280, FRAME_H=720, FRAME_LINES_16 together with MULTI/PPC/clk_pix.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
ABI = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_abi_select.svh"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"


def main() -> int:
    fails: list[str] = []
    core = CORE.read_text(errors="replace")
    abi = ABI.read_text(errors="replace") if ABI.is_file() else ""
    qsf = QSF.read_text(errors="replace")

    if not ABI.is_file():
        fails.append("missing ddr_frame_abi_select.svh")
    if "ddr_frame_abi_select.svh" not in core:
        fails.append("present_core must include ddr_frame_abi_select.svh")
    if "DDR_FS_USE_720P_ABI" not in abi:
        fails.append("abi select missing DDR_FS_USE_720P_ABI")
    if "FRAME_W == 1280" not in abi or "FRAME_H == 720" not in abi:
        fails.append("abi select must key off FRAME 1280x720")

    # NEGATIVE pattern: 720p coded bind only inside L4 ifdef (old bug)
    # After fix, FS_CODED_W comes from DDR_FS_CODED_W, not ifdef L4 alone.
    if re.search(
        r"`ifdef\s+PLEX_PRESENT_720P_L4\s+"
        r"localparam\s+int\s+FS_CODED_W\s*=\s*DDR_FRAME_720P_CODED_WIDTH",
        core,
    ):
        fails.append("REGRESSION: FS_CODED_W still L4-only ifdef (MULTI broken)")

    if "FS_CODED_W     = DDR_FS_CODED_W" not in core and "FS_CODED_W = DDR_FS_CODED_W" not in core.replace(" ", ""):
        # allow whitespace variants
        if "DDR_FS_CODED_W" not in core:
            fails.append("present_core must assign FS_* from DDR_FS_* shared select")

    if "FS_LINE_COUNT" not in core or ".LINE_COUNT(FS_LINE_COUNT)" not in core:
        fails.append("ddr_frame_store must use FS_LINE_COUNT (16-line 720p floor)")

    # MULTI elab requires FRAME 1280x720
    if "PRESENT_MULTI_PIXEL requires FRAME_W=1280" not in core:
        fails.append("MULTI path must $error unless FRAME 1280x720")

    # QSF recipe: commented MULTI + FRAME 1280 + LINES_16 (default-off)
    def commented_recipe(macro: str) -> bool:
        return any(
            macro in ln and ln.strip().startswith("#") for ln in qsf.splitlines()
        )

    for m in (
        "PRESENT_MULTI_PIXEL=1",
        "FRAME_W=1280",
        "FRAME_H=720",
        "FRAME_LINES_16=1",
        "PRESENT_PX_PER_CLK=2",
        "PRESENT_CLK_PIX_PLL=1",
    ):
        if not commented_recipe(m):
            fails.append(f"QSF missing commented MULTI 720p recipe piece: {m}")

    # Product default still 640x480 / LINES_8 active
    act = re.findall(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"',
        qsf,
        re.M,
    )
    if not any(m.startswith("FRAME_W=640") for m in act):
        fails.append("product default FRAME_W=640 must stay active")
    if any(m.startswith("PRESENT_MULTI_PIXEL") for m in act):
        fails.append("PRESENT_MULTI_PIXEL must stay default-OFF")

    if fails:
        print("FAIL test_present_multi_720p_abi_static")
        for f in fails:
            print(" ", f)
        return 1
    print(
        "PASS multi_720p_abi: shared FRAME-keyed ABI; MULTI recipe "
        "FRAME1280+LINES16+PPC2+clk_pix; default 480p intact"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
