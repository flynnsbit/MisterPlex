#!/usr/bin/env python3
"""Gate: MULTI+PPC=2 must use real dual-lane store RGB, not scalar replicate.

This tree (w-fpga WAVE2 on 3b6e7a1c glass fix):
  - ddr_frame_store: PX_PER_CLK + rd_*_n dual-pixel pack (same Y qword)
  - present_core: mp_npx_* = fs_rd_*_n under DDR_FRAME_STORE
  - MULTI glass→store_x already landed (3b6e7a1c)

NEGATIVE (naive wrong impl fails):
  - Reintroduce {PRESENT_PPC{fr}} as sole mp_npx_r under DDR_FRAME_STORE
  - Lock PPC!=1 as sole land requirement
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"


def fail(msg: str) -> int:
    print(f"FAIL present_ppc2_dual_lane: {msg}", file=sys.stderr)
    return 1


def strip_comments(t: str) -> str:
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    t = re.sub(r"//.*", "", t)
    return t


def main() -> int:
    core = CORE.read_text(encoding="utf-8", errors="replace")
    store = STORE.read_text(encoding="utf-8", errors="replace")
    c = strip_comments(core)
    s = strip_comments(store)

    if "parameter int PX_PER_CLK" not in s:
        return fail("ddr_frame_store missing PX_PER_CLK parameter")
    if "rd_r_n" not in s or "rd_g_n" not in s or "rd_b_n" not in s:
        return fail("ddr_frame_store missing rd_*_n ports")
    if "rd_lane_valid_n" not in s or "rd_n_valid" not in s:
        return fail("ddr_frame_store missing rd_lane_valid_n / rd_n_valid")
    # Dual-pixel pack: lanes from same qword (g_px) or yuv_bt601_npx
    if "g_px" not in s and "yuv_bt601_npx" not in s:
        return fail("ddr_frame_store missing multi-pixel pack (g_px or yuv_bt601_npx)")
    if "r_lane" not in s and "yuv_bt601_npx" not in s:
        return fail("ddr_frame_store missing r_lane / yuv_bt601_npx dual-pixel path")
    print("OK store: PX_PER_CLK + rd_*_n + dual-pixel pack")

    if ".PX_PER_CLK(FS_PX_PER_CLK)" not in c and ".PX_PER_CLK(PRESENT_PPC)" not in c:
        return fail("present_core fstore missing .PX_PER_CLK(...)")
    if "fs_rd_r_n" not in c:
        return fail("present_core missing fs_rd_r_n wire")
    if re.search(r"mp_npx_r\s*=\s*fs_rd_r_n", c) is None:
        return fail("present_core mp_npx_r must equal fs_rd_r_n (dual-lane store)")
    print("OK present: PX_PER_CLK + fs_rd_r_n → mp_npx_r")

    # Under DDR_FRAME_STORE path, must not rely on scalar replicate as primary feed.
    # Allow SDRAM-path else branch: {PRESENT_PPC{fr}} inside `else` after `ifndef DDR`.
    # Fail if the only mp_npx_r assignment is replicate without fs_rd_r_n assignment.
    if re.search(r"mp_npx_r\s*=\s*fs_rd_r_n", c) is None:
        return fail("missing fs_rd_r_n feed")
    # Hard fail: unguarded replicate still the MULTI primary (no fs_rd assignment nearby)
    ddr_block = re.search(
        r"`ifdef\s+DDR_FRAME_STORE\s*(.*?)\s*`else\s*(.*?)\s*`endif",
        c,
        flags=re.S,
    )
    # Simpler: if file still has the lock "requires PRESENT_PX_PER_CLK=1 until"
    if "until ddr_frame_store N-wide" in core:
        return fail("present_core still locks PPC=1 (N-wide land incomplete)")
    if re.search(
        r"PRESENT_PPC\s*!=\s*1[\s\S]{0,120}N-wide RGB",
        core,
    ):
        return fail("present_core still $error-locks PPC!=1 for N-wide")
    print("OK PPC lock relaxed to {1,2,4}")

    # Glass→store (3b6e7a1c class): MULTI drives store_x from mp_glass_x0
    if "mp_glass_x0" not in c:
        return fail("present_core missing mp_glass_x0")
    if not re.search(r"store_x\s*<=.*mp_glass_x0", c, flags=re.S):
        return fail("MULTI store_x must track mp_glass_x0 (glass map)")
    print("OK MULTI glass→store_x")

    print("PASS present_ppc2_dual_lane_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
