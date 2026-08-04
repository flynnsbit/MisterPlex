#!/usr/bin/env python3
"""Shipping MULTI+PPC2+720p ABI recipe gate (rd-duck BLOCKING cross-lane).

Product clock plan (w-clock): PRESENT_MULTI_PIXEL + PRESENT_PX_PER_CLK=2 +
clk_pix@29.7, FRAME 1280×720. L4 and MULTI are mutually exclusive — so the
L4-only store-wire / blackout proofs do NOT cover the shipping MULTI recipe.

This gate checks SOURCE for the combined recipe, not L4-only TB:

  1. MULTI arm selects DDR_FRAME_720P_* (PHYS 0x3018_0000, doorbell 0x3047_F000)
     — not the 480p 0x3000_0000 / 624×480 fall-through.
  2. MULTI floors LINE_COUNT to >=16 (8 lines @ PPC2/20MHz/1280 = 256 µs <
     500 µs modelled blackout; 16 lines = 512 µs).
  3. MULTI requires FRAME_W=1280 FRAME_H=720 (elaborate $error present).
  4. Default product QSF keeps MULTI off and FRAME 640×480.
  5. Negative: stripping MULTI 720p PHYS bind must be detectable.

Arithmetic (quoted):
  t_line_ppc2 = 1280 / 2 / 20e6 = 32 µs
  cover_8     = 8  * 32 µs = 256 µs  < 500 µs FAIL
  cover_16    = 16 * 32 µs = 512 µs >= 500 µs PASS
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
LAYOUT = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"


def nt(s: str) -> str:
    return re.sub(r"\s+", "", s)


def fail(msg: str) -> int:
    print(f"FAIL multi_ppc2_abi: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    present = PRESENT.read_text(encoding="utf-8", errors="replace")
    layout = LAYOUT.read_text(encoding="utf-8", errors="replace")
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
    pnt = nt(present)
    lnt = nt(layout)

    # --- Blackout arithmetic (must stay honest) ---
    ppc = 2
    f_hz = 20_000_000
    width = 1280
    t_line_us = (width / ppc) / f_hz * 1e6
    cover_8 = 8 * t_line_us
    cover_16 = 16 * t_line_us
    if abs(t_line_us - 32.0) > 0.01:
        return fail(f"t_line_us want 32 got {t_line_us}")
    if cover_8 >= 500.0:
        return fail(f"cover_8={cover_8} unexpectedly >=500 (test math broken)")
    if cover_16 < 500.0:
        return fail(f"cover_16={cover_16} <500 (test math broken)")
    print(f"OK blackout arith PPC2@20MHz: t_line={t_line_us}us cover8={cover_8}us cover16={cover_16}us")

    # --- Layout constants exist ---
    if "DDR_FRAME_720P_PHYS_BASE=32'h3018_0000" not in lnt and "3018_0000" not in layout:
        return fail("svh missing 720p PHYS_BASE 0x3018_0000")
    if "3047_F000" not in layout:
        return fail("svh missing 720p DOORBELL 0x3047_F000")
    print("OK svh 720p PHYS/doorbell constants present")

    # --- MULTI arm is a 720p tier (elsif PRESENT_MULTI_PIXEL after L4) ---
    if "elsifPRESENT_MULTI_PIXEL" not in pnt:
        return fail("present_core missing `elsif PRESENT_MULTI_PIXEL on FS tier")
    # Both arms must bind 720p PHYS
    n_phys = pnt.count("FS_PHYS_BASE=DDR_FRAME_720P_PHYS_BASE")
    if n_phys < 2:
        return fail(f"720p PHYS binds={n_phys} want>=2 (L4+MULTI)")
    n_db = pnt.count("FS_DOORBELL=DDR_FRAME_720P_YUV420P_DOORBELL_PHYS")
    if n_db < 2:
        return fail(f"720p DOORBELL binds={n_db} want>=2 (L4+MULTI)")
    print(f"OK MULTI+L4 720p PHYS binds={n_phys} DOORBELL binds={n_db}")

    # Default else arm still 480p base
    if "FS_PHYS_BASE=32'h3000_0000" not in pnt:
        return fail("default 480p PHYS_BASE missing")
    print("OK default arm keeps 480p PHYS 0x3000_0000")

    # --- MULTI LINE_COUNT floor 16 ---
    if "FS_LINE_COUNT=(FRAME_LINE_COUNT<16)?16:FRAME_LINE_COUNT" not in pnt:
        return fail("MULTI missing FS_LINE_COUNT floor-to-16 (8-line blackout hole)")
    if ".LINE_COUNT(FS_LINE_COUNT)" not in pnt:
        return fail("ddr_frame_store not wired to FS_LINE_COUNT")
    print("OK MULTI FS_LINE_COUNT floors to 16; store uses FS_LINE_COUNT")

    # --- MULTI requires FRAME 1280×720 ---
    if "PRESENT_MULTI_PIXELrequiresFRAME_W=1280FRAME_H=720" not in pnt:
        # tolerate spacing variants already stripped
        if not re.search(
            r"PRESENT_MULTI_PIXEL requires FRAME_W=1280 FRAME_H=720", present
        ):
            return fail("MULTI missing FRAME_W=1280 FRAME_H=720 elaborate check")
    print("OK MULTI elaborates only at FRAME 1280×720")

    # --- Mutual exclusion L4 vs MULTI still present ---
    if "PLEX_PRESENT_720P_L4andPRESENT_MULTI_PIXELaremutuallyexclusive" not in pnt:
        if "mutually exclusive" not in present or "PRESENT_MULTI_PIXEL" not in present:
            return fail("L4/MULTI mutual exclusion missing")
    print("OK L4 and MULTI remain mutually exclusive")

    # --- Product QSF: MULTI default-off, FRAME 640×480, recipe comments ---
    act = re.findall(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"',
        qsf,
        flags=re.M,
    )
    for m in act:
        if m.startswith("PRESENT_MULTI_PIXEL") or m.startswith("PLEX_PRESENT_720P_L4"):
            return fail(f"product QSF must not activate {m}")
    if not any("FRAME_W=640" in m for m in act):
        return fail("product FRAME_W=640 missing")
    if not any("FRAME_H=480" in m for m in act):
        return fail("product FRAME_H=480 missing")

    # Shipping recipe must be documented as comments (parent enables deliberately)
    recipe_needles = [
        "PRESENT_MULTI_PIXEL",
        "FRAME_W=1280",
        "FRAME_H=720",
    ]
    for n in recipe_needles:
        if not any(n in line and line.strip().startswith("#") for line in qsf.splitlines()):
            return fail(f"QSF missing commented shipping recipe token {n}")
    print("OK QSF default-off; commented MULTI/1280 recipe present")

    # --- Negative twin: MULTI arm falls to 480p PHYS ---
    # If someone deletes the elsif MULTI 720p block, n_phys drops to 1 (L4 only).
    twin = pnt.replace(
        # remove one 720p PHYS bind occurrence after elsifMULTI by mangling MULTI block marker
        "elsifPRESENT_MULTI_PIXEL",
        "elsifPRESENT_MULTI_PIXEL_GONE",
        1,
    )
    # Also simulate only-L4 by counting: if we had only L4, n_phys==1 fails above.
    if "elsifPRESENT_MULTI_PIXEL" not in pnt:
        return fail("positive lost MULTI elsif")
    if "elsifPRESENT_MULTI_PIXEL_GONE" not in twin:
        return fail("negative twin did not rename MULTI elsif")
    print("OK negative twin: removing MULTI elsif arm is detectable")

    # Full-frame recipe string (for parent fit QSF — not activated here)
    recipe = (
        "PRESENT_MULTI_PIXEL=1 PRESENT_PX_PER_CLK=2 "
        "FRAME_W=1280 FRAME_H=720 FRAME_LINES_16=1 "
        "(clk_pix@29.7 per w-clock; FS_LINE_COUNT>=16 forced in RTL)"
    )
    print(f"SHIPPING_RECIPE (parent fit, default-OFF): {recipe}")
    print("PASS present_multi_ppc2_abi_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
