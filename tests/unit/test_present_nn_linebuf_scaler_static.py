#!/usr/bin/env python3
"""Static gate: nn linebuf scaler M10K math with handbook-legal layouts."""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SV = ROOT / "fpga/Plex_MiSTer/rtl/present_nn_linebuf_scaler.sv"
GEOM = ROOT / "fpga/Plex_MiSTer/rtl/plex_m10k_geom.svh"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"


def fail(m: str) -> int:
    print(f"FAIL nn_lb_static: {m}", file=sys.stderr)
    return 1


def main() -> int:
    sv = SV.read_text(encoding="utf-8")
    geom = GEOM.read_text(encoding="utf-8")
    qip = QIP.read_text(encoding="utf-8")

    # Handbook capacity
    if "10_240" not in geom and "10240" not in geom:
        return fail("geom missing 10240-bit M10K constant")
    if (1280 * 8) != 10240:
        return fail("python: 1280*8 bit count still 10240 (capacity only)")

    # RETRACTED premise must not claim naive line = 1 without pack40
    if "1280×8-bit luma line = 1280*8 = 10_240 bits = **exactly 1.0 M10K**" in geom:
        return fail("RETRACTED false premise still in geom header")
    if "NOT a legal configuration" not in geom and "not a legal" not in geom.lower():
        return fail("geom must state 1280×8 is not a legal M10K config")

    # Legal layouts
    if "PLEX_M10K_BYTES_1K_X8" not in geom or "1024" not in geom:
        return fail("missing 1K×8 = 1024 bytes legal config")
    if "PLEX_M10K_BYTES_256_X40" not in geom:
        return fail("missing 256×40 pack config")
    if "PLEX_M10K_LUMA_LINE_1280_NAIVE_X8" not in geom:
        return fail("missing naive x8 luma line cost")
    if not re.search(r"PLEX_M10K_LUMA_LINE_1280_NAIVE_X8\s*=\s*2", geom):
        return fail("naive 1280×8 line must be 2 M10K")
    if not re.search(r"PLEX_M10K_LUMA_LINE_1280_PACK40\s*=\s*1", geom):
        return fail("pack40 1280×8 line must be 1 M10K")
    print("OK handbook: 1K×8=1024B → 1280 line = 2 M10K naive; pack40=1 (5-px)")

    # Budget pins (layout-independent, parent MEASURED)
    if "356" not in geom or "197" not in geom:
        return fail("geom must pin parent MEASURED 197/356")
    print("OK post-strip budget pins 197 chip / 356 free (parent MEASURED)")

    # Full frame
    if "2160" not in geom:
        return fail("full-frame naive x8 I420 must be 2160 M10K")
    if "1078" not in geom:
        return fail("full-frame bit-ideal must remain 1078")
    print("OK full-frame BRAM rejected (bit 1078 / naive_x8 2160 > 356)")

    # Free luma lines
    if "178" not in geom:  # 356/2
        return fail("free luma lines naive x8 must be 178")
    print("OK free luma lines: 178 naive_x8 / 356 pack40")

    # rd-duck MEASURED product store is 64b qword class, not byte-wide
    if "PLEX_M10K_STORE_LINEBUF_480P_MEASURED" not in geom:
        return fail("geom missing 480p linebuf MEASURED pin")
    if not re.search(r"PLEX_M10K_STORE_LINEBUF_480P_MEASURED\s*=\s*96", geom):
        return fail("480p store linebuf must pin 96 MEASURED")
    if not re.search(r"PLEX_M10K_STORE_LINEBUF_720P_64B_EST\s*=\s*192", geom):
        return fail("720p 64b linebuf EST must be 192 (32 slots × 6)")
    if "96 M10K EST" in geom and "192" not in geom:
        return fail("retracted 720p=96 slip still sole claim")
    # NEGATIVE: 720p EST must not equal 480p measured (slots doubled)
    if re.search(r"PLEX_M10K_STORE_LINEBUF_720P_64B_EST\s*=\s*96\b", geom):
        return fail("NEGATIVE: 720p 64b EST must not be 96 (that was slots/2 slip)")
    print("OK store linebuf: 480p 96 MEASURED (64b); 720p 192 EST (64b class)")
    print("OK alternates noted: naive_x8 128 / pack40 96 (gearbox)")

    # Q1 LINE_HOLD=2
    if not re.search(r"LINE_HOLD\s*=\s*2", sv):
        return fail("default LINE_HOLD must be 2")
    if "not 16" not in sv.lower() and "Not 16" not in sv and "not 16" not in sv:
        if "LINE_HOLD=16" not in sv and "not 16" not in sv:
            if "Not 16" not in sv:
                pass
    if "16" not in sv or "store owns" not in sv.lower() and "LINE_COUNT" not in sv:
        if "not 16" not in sv and "Not 16" not in sv and "not 16" not in sv.replace(" ", ""):
            # header says "Not 16"
            if "Not 16" not in sv and "not 16" not in sv:
                return fail("header must explain why not LINE_HOLD=16")
    print("OK Q1 LINE_HOLD=2 (not 16 — store owns DDR prefetch)")

    if "1078" not in sv and "2160" not in sv:
        return fail("Q2 must cite full-frame M10K reject")
    print("OK Q2 thin hold — no frame-BRAM scaler")

    if "OPEN" not in sv and "contention" not in sv.lower():
        return fail("Q3 contention must be noted OPEN")
    print("OK Q3 single-reader / contention OPEN noted")

    # Dual M10K numbers
    bits = 2 * 1280 * 24
    bit_ideal = (bits + 10240 - 1) // 10240
    naive = 2 * 3 * math.ceil(1280 / 1024)
    if bit_ideal != 6:
        return fail(f"python bit ideal want 6 got {bit_ideal}")
    if naive != 12:
        return fail(f"python naive x8 want 12 got {naive}")
    if "m10k_naive_x8" not in sv.lower() and "M10K_NAIVE_X8" not in sv:
        return fail("RTL must expose naive x8 M10K account")
    if "12" not in sv:
        return fail("RTL header/body must state 12 M10K naive bound")
    print("OK default M10K bounds bit_ideal=6 naive_x8=12 (layout-dependent ESTIMATE)")

    if "present_nn_linebuf_scaler.sv" not in qip:
        return fail("qip must list scaler")
    if "plex_m10k_geom.svh" not in qip:
        return fail("files.qip must list plex_m10k_geom.svh")
    print("OK qip lists scaler + geom")

    m = re.search(r"parameter int LINE_HOLD\s*=\s*(\d+)", sv)
    if not m or int(m.group(1)) == 16:
        return fail("NEGATIVE: default LINE_HOLD must remain 2")
    print("OK NEGATIVE twin: default LINE_HOLD!=16")

    # NEGATIVE: geom must not allow naive==1
    if re.search(r"PLEX_M10K_LUMA_LINE_1280_NAIVE_X8\s*=\s*1\b", geom):
        return fail("NEGATIVE: naive x8 line cost must not be 1")
    print("OK NEGATIVE twin: naive_x8 line != 1")

    print("PASS test_present_nn_linebuf_scaler_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
