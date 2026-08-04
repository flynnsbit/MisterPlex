#!/usr/bin/env python3
"""L4 must force FRAME_LINE_COUNT>=16 even when FRAME_LINES_8 remains in QSF.

RED if present_core still maps FRAME_LINES_8 -> 8 under PLEX_PRESENT_720P_L4.
Equal-strength: non-L4 FRAME_LINES_8 must still be COUNT=8 (product default).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"


def fail(m: str) -> int:
    print(f"FAIL: {m}", file=sys.stderr)
    return 1


def main() -> int:
    p = PRESENT.read_text(encoding="utf-8", errors="replace")
    q = QSF.read_text(encoding="utf-8", errors="replace")

    # Capture the FRAME_LINES_8 arm up to the outer `else that follows its `endif.
    m = re.search(
        r"`elsif\s+FRAME_LINES_8\s*\n"
        r"(.*?)\n"
        r"`else\s*\n"
        r"\s*`ifdef\s+PLEX_PRESENT_720P_L4",
        p,
        re.S,
    )
    if not m:
        return fail("FRAME_LINES_8 arm (with outer `else L4 fallback) not found")
    arm = m.group(1)

    if "PLEX_PRESENT_720P_L4" not in arm:
        return fail("FRAME_LINES_8 arm does not special-case PLEX_PRESENT_720P_L4")

    # Nested: ifdef L4 -> 16; else -> 8
    if not re.search(
        r"`ifdef\s+PLEX_PRESENT_720P_L4\s*\n\s*parameter\s+int\s+FRAME_LINE_COUNT\s*=\s*16",
        arm,
    ):
        return fail("FRAME_LINES_8 + L4 must set FRAME_LINE_COUNT=16")
    if not re.search(
        r"`else\s*\n\s*parameter\s+int\s+FRAME_LINE_COUNT\s*=\s*8",
        arm,
    ):
        return fail("non-L4 FRAME_LINES_8 path missing COUNT=8")

    # Explicit FRAME_LINES_16 still wins (higher priority elsif)
    if not re.search(
        r"`elsif\s+FRAME_LINES_16\s*\n\s*parameter\s+int\s+FRAME_LINE_COUNT\s*=\s*16",
        p,
    ):
        return fail("FRAME_LINES_16 arm missing COUNT=16")

    if "FRAME_LINE_COUNT < 16" not in p:
        return fail("missing L4 elab guard FRAME_LINE_COUNT < 16")

    # Default-off: L4 must not be live-enabled in QSF
    if re.search(r"^\s*set_global_assignment.*PLEX_PRESENT_720P_L4=1", q, re.M):
        return fail("L4 must stay default-off in QSF")
    if not re.search(r"^[^#\n]*FRAME_LINES_8=1", q, re.M):
        return fail("product FRAME_LINES_8 missing")

    print("PASS test_l4_frame_lines16_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
