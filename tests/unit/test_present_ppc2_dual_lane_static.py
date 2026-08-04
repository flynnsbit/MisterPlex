#!/usr/bin/env python3
"""Gate: MULTI+PPC=2 must use real dual-lane store RGB, not scalar replicate.

rd-duck FIT BLOCKER (quoted defects before fix):
  - translate_off $error for PPC!=1 (synthesis ignored)
  - mp_npx_* = {PPC{fr}} duplicates pixels / half horizontal information
  - mp_glass unused; fstore still on Template store_x/y

POSITIVE (this branch):
  - fstore_rd_x driven from mp_store_x_r (glass clamp)
  - mp_npx_r = fs_r_n (N-wide store)
  - .PX_PER_CLK(PRESENT_PPC) on ddr_frame_store
  - mp_recipe_ok synthesis-active localparam/wire
  - store emits distinct lanes (yuv_bt601_npx OR inline y_sel_r+gpi)

NEGATIVE (naive wrong impl fails):
  - Reintroduce {PRESENT_PPC{fr}} as mp_npx_r → FAIL
  - Leave glass only in _unused without fstore_rd → FAIL
  - PPC gate only under translate_off without mp_recipe_ok → FAIL
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
NPX = ROOT / "fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv"


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

    if "parameter int PX_PER_CLK" not in store and "parameter int PX_PER_CLK" not in s:
        return fail("ddr_frame_store missing PX_PER_CLK parameter")
    if "rd_r_n" not in s:
        return fail("ddr_frame_store missing rd_r_n port")
    # Accept yuv_bt601_npx module OR inlined multi-pixel generate (same math).
    has_npx_mod = "yuv_bt601_npx" in s
    has_inline = ("r_lane" in s and "y_sel_r" in s and "PX_PER_CLK" in s
                  and re.search(r"y_sel_r\s*\+\s*3'\(gpi\)", s) is not None)
    if not has_npx_mod and not has_inline:
        return fail("store missing N-wide path (yuv_bt601_npx or inline y_sel_r+gpi)")
    print(f"OK store: PX_PER_CLK + rd_r_n + {'npx_mod' if has_npx_mod else 'inline_gen'}")

    if ".PX_PER_CLK(PRESENT_PPC)" not in c and ".PX_PER_CLK(PRESENT_PPC)" not in core:
        return fail("present_core fstore missing .PX_PER_CLK(PRESENT_PPC)")
    if "fstore_rd_x" not in c:
        return fail("present_core missing fstore_rd_x mux (glass→store)")
    if "mp_store_x_r" not in c:
        return fail("present_core missing mp_store_x_r (registered glass map)")
    if re.search(r"mp_npx_r\s*=\s*fs_r_n", c) is None:
        return fail("present_core mp_npx_r must equal fs_r_n (dual-lane store)")
    if "mp_recipe_ok" not in c:
        return fail("present_core missing synthesis-active mp_recipe_ok")
    if "MP_RECIPE_OK" not in c:
        return fail("present_core missing MP_RECIPE_OK localparam")
    print("OK present: glass→store, fs_r_n feed, mp_recipe_ok")

    if re.search(r"mp_npx_r\s*=\s*\{PRESENT_PPC\{fr\}\}", c):
        return fail("NEGATIVE: mp_npx_r still replicates scalar fr across lanes")
    if re.search(r"mp_npx_g\s*=\s*\{PRESENT_PPC\{fg\}\}", c):
        return fail("NEGATIVE: mp_npx_g still replicates scalar fg")
    if re.search(r"mp_npx_b\s*=\s*\{PRESENT_PPC\{fb\}\}", c):
        return fail("NEGATIVE: mp_npx_b still replicates scalar fb")
    print("OK NEGATIVE twin: no {PPC{fr/g/b}} replicate on mp_npx_*")

    if not re.search(r"fstore_rd_x\s*=\s*mp_store_x_r", c):
        return fail("fstore_rd_x not assigned from mp_store_x_r")
    print("OK glass drives fstore_rd_x")

    # Beam enable must AND recipe (not only translate_off $error).
    if "mp_recipe_ok" not in c or not re.search(
        r"mp_beam_en\s*=\s*[^;]*mp_recipe_ok", c
    ):
        return fail("mp_beam_en must include mp_recipe_ok (synth-active freeze)")
    print("OK mp_beam_en gated by mp_recipe_ok")

    if re.search(
        r"synthesis\s+translate_off[\s\S]*?PRESENT_PPC\s*!=\s*1[\s\S]*?translate_on",
        core,
        flags=re.I,
    ):
        if "mp_recipe_ok" not in c:
            return fail("NEGATIVE: PPC gate only in translate_off without mp_recipe_ok")
    print("OK recipe gate not translate_off-only")

    npx = NPX.read_text(encoding="utf-8", errors="replace")
    if "src_x0 + X_W'(gi)" not in npx and "src_x0+" not in npx.replace(" ", ""):
        return fail("yuv_bt601_npx must index lane i at src_x0+i (odd/even distinct)")
    print("OK yuv_bt601_npx lane i = src_x0+i (odd/even distinct when Y differs)")

    print("PASS present_ppc2_dual_lane_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
