#!/usr/bin/env python3
"""Static: LINE_SLOTS is deliberate 2× LINE_COUNT (disp+prep), not a QSF bug.

p720probe1 map shows gen_line[0..31] (n=32) under FRAME_LINES_16. Parent asked
why 32 not 16 before any "fix". This gate locks the RTL identity:

  LINE_SLOTS = LINE_COUNT * 2
  SECOND_SET_BASE = LINE_COUNT
  disp_buf selects display set; prep uses the other set.

Also asserts 720p PACK_PX5 generate (256×40 path) is present so the measured
64-bit waste on p720probe1 is addressed on this branch.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"


def main() -> int:
    text = STORE.read_text(encoding="utf-8", errors="replace")
    # strip comments for assignment hunt
    bare = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    bare = re.sub(r"//.*?$", "", bare, flags=re.M)

    if not re.search(
        r"localparam\s+int\s+LINE_SLOTS\s*=\s*LINE_COUNT\s*\*\s*2\s*;", bare
    ):
        print("FAIL: expected LINE_SLOTS = LINE_COUNT * 2 (disp+prep double-buffer)")
        return 1

    if not re.search(
        r"SECOND_SET_BASE\s*=\s*SLOT_W'\(LINE_COUNT\)", bare
    ) and not re.search(
        r"localparam\s+\[SLOT_W-1:0\]\s+SECOND_SET_BASE\s*=\s*SLOT_W'\(LINE_COUNT\)",
        bare,
    ):
        print("FAIL: expected SECOND_SET_BASE = LINE_COUNT")
        return 1

    if "disp_buf" not in bare or "prep_base_idx" not in bare:
        print("FAIL: expected disp_buf / prep_base_idx double-buffer schedule")
        return 1

    # NEGATIVE: must NOT be LINE_SLOTS = LINE_COUNT alone (would drop prep set)
    if re.search(r"localparam\s+int\s+LINE_SLOTS\s*=\s*LINE_COUNT\s*;", bare):
        print("FAIL NEGATIVE: LINE_SLOTS = LINE_COUNT alone collapses prep set")
        return 1

    if "PACK_PX5" not in bare or "line_buf_ram_px5" not in text:
        print("FAIL: PACK_PX5 / line_buf_ram_px5 missing — 64b waste unaddressed")
        return 1

    if not re.search(
        r"PACK_PX5\s*=\s*\(CODED_W\s*==\s*1280\)\s*&&\s*\(CODED_H\s*==\s*720\)",
        bare,
    ):
        print("FAIL: PACK_PX5 must be 720p-only (1280x720)")
        return 1

    print(
        "PASS line_buf double-buffer: LINE_SLOTS=2*LINE_COUNT (disp+prep); "
        "FRAME_LINES_16 => 32 slots is intentional; PACK_PX5 720p path present"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
