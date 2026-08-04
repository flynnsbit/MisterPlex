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

    # rd-duck FIT BLOCKER: PPC2 must use real dual-lane store, not scalar replicate.
    multi = re.search(r"`ifdef\s+PRESENT_MULTI_PIXEL\s*(.*?)\s*`else\s*\n\s*assign r = leg_r", core, re.S)
    multi_body = multi.group(1) if multi else core
    # Dual-lane RGB from store (direct or via mp_store_r = fs_rd_r_n + quality gate)
    if "fs_rd_r_n" not in multi_body:
        fails.append("MULTI must source RGB from fs_rd_r_n (dual-lane store)")
    if not re.search(r"mp_store_r\s*=\s*fs_rd_r_n", multi_body) and not re.search(
        r"mp_npx_r\s*=\s*fs_rd_r_n", multi_body
    ):
        fails.append("MULTI must wire store RGB from fs_rd_r_n (dual-lane)")
    # rd-duck: fs_rd_n_valid must gate RGB/lane — never leave as _unused only
    if re.search(r"wire\s+_unused_fs_n_valid\s*=\s*fs_rd_n_valid", multi_body):
        fails.append("MULTI must not discard fs_rd_n_valid as _unused (gate RGB/lane)")
    if "fs_rd_n_valid" not in multi_body and "mp_store_nv" not in multi_body:
        fails.append("MULTI must consume fs_rd_n_valid")
    if "mp_store_rgb_ok" not in multi_body and "fs_rd_n_valid" not in multi_body:
        fails.append("MULTI must quality-gate RGB on store valid")
    if "in_lane_valid(mp_npx_lv)" not in multi_body.replace(" ", "") and \
       ".in_lane_valid(mp_npx_lv)" not in multi_body:
        # allow whitespace
        if not re.search(r"\.in_lane_valid\s*\(\s*mp_npx_lv\s*\)", multi_body):
            fails.append("MULTI npx path must take in_lane_valid(mp_npx_lv) (store-gated)")
    if not re.search(r"fs_rd_x_w\s*=\s*mp_store_x", multi_body):
        fails.append("MULTI must drive fs_rd_x_w from mp_store_x (beam glass→store)")
    if not re.search(r"fs_rd_y_w\s*=\s*mp_store_y", multi_body):
        fails.append("MULTI must drive fs_rd_y_w from mp_store_y (beam glass→store)")
    if not re.search(r"fs_vsync_w\s*=\s*mp_fstart", multi_body):
        fails.append("MULTI must drive fs_vsync_w from mp_fstart (not legacy fstart)")
    if "vsync_pulse(fs_vsync_w)" not in core and ".vsync_pulse(fs_vsync_w)" not in core:
        fails.append("fstore must take vsync_pulse(fs_vsync_w)")
    if "g_mp_ppc_needs_ddr" not in multi_body and "present_multi_ppc_requires_ddr_frame_store" not in multi_body:
        fails.append("MULTI+PPC>1 needs synthesis-active DDR_FRAME_STORE gate")
    # Inside MULTI+DDR path: no scalar replicate of fr
    if re.search(r"`ifdef\s+DDR_FRAME_STORE[\s\S]*?\{PRESENT_PPC\{fr\}\}", multi_body):
        # only fail if replicate appears before the else of that ifdef
        m2 = re.search(r"`ifdef\s+DDR_FRAME_STORE\s*([\s\S]*?)`else", multi_body)
        if m2 and "{PRESENT_PPC{fr}}" in m2.group(1).replace(" ", ""):
            fails.append("DDR_FRAME_STORE MULTI path must not replicate {PRESENT_PPC{fr}}")

    # QSF recipe: MULTI + FRAME 1280 + clk_pix present (active product-ON or comment)
    def recipe_present(macro: str) -> bool:
        return any(macro in ln for ln in qsf.splitlines())

    for m in (
        "PRESENT_MULTI_PIXEL=1",
        "FRAME_W=1280",
        "FRAME_H=720",
        "FRAME_LINES_16=1",
        "PRESENT_PX_PER_CLK=2",
        "PRESENT_CLK_PIX_PLL=1",
    ):
        if not recipe_present(m):
            fails.append(f"QSF missing MULTI 720p recipe piece: {m}")

    # Product 720p MULTI + clk_pix LIVE (w-clock integration candidate)
    act = re.findall(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"',
        qsf,
        re.M,
    )
    if not any(m.startswith("FRAME_W=1280") for m in act):
        fails.append("product FRAME_W=1280 must be active")
    if not any(m.startswith("PRESENT_MULTI_PIXEL") for m in act):
        fails.append("PRESENT_MULTI_PIXEL must be product-ON")
    if not any(m == "PRESENT_CLK_PIX_PLL=1" for m in act):
        fails.append("PRESENT_CLK_PIX_PLL must be product-ON")

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
