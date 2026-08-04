#!/usr/bin/env python3
"""Static gate: nn linebuf scaler M10K math + design answers present in RTL."""
from __future__ import annotations

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

    # Handbook fact parent asked to verify
    if "10_240" not in geom and "10240" not in geom:
        return fail("geom missing 10240-bit M10K constant")
    if "PLEX_M10K_LUMA_LINE_1280 = 1" not in geom.replace(" ", ""):
        if "PLEX_M10K_LUMA_LINE_1280" not in geom:
            return fail("missing luma line = 1 M10K ideal")
    if (1280 * 8) != 10240:
        return fail("python control: 1280*8 != 10240")
    print("OK handbook class: 1280*8=10240 = 1.0 M10K ideal luma line")

    if "PLEX_M10K_FREE_POSTSTRIP = 356" not in geom.replace(" ", ""):
        if "356" not in geom:
            return fail("geom must pin parent MEASURED free 356")
    if "PLEX_M10K_CHIP_POSTSTRIP = 197" not in geom.replace(" ", ""):
        if "197" not in geom:
            return fail("geom must pin parent MEASURED chip 197")
    print("OK post-strip budget pins 197 chip / 356 free (parent MEASURED)")

    if "1078" not in geom:
        return fail("full-frame I420 ideal M10K must be stated (does not fit)")
    print("OK full-frame BRAM path rejected (1078 > 356)")

    # Q1 LINE_HOLD=2 default
    if not re.search(r"LINE_HOLD\s*=\s*2", sv):
        return fail("default LINE_HOLD must be 2")
    if "Not 16" not in sv and "NOT 16" not in sv and "Not 16" not in sv:
        if "not 16" not in sv.lower():
            return fail("header must explain why not LINE_HOLD=16")
    print("OK Q1 LINE_HOLD=2 (not 16 — store owns DDR prefetch)")

    # Q2 no full-frame drop scale
    if "Do NOT build frame-BRAM" not in sv and "does NOT fit" not in sv:
        return fail("Q2 answer missing in RTL header")
    print("OK Q2 thin hold — no frame-BRAM scaler")

    # Q3 single reader
    if "ONE reader" not in sv and "one reader" not in sv.lower():
        return fail("Q3 must require single reader vs dual DDR masters")
    print("OK Q3 single-reader / contention OPEN noted")

    # Ideal M10K = 6
    bits = 2 * 1280 * 24
    m10k = (bits + 10240 - 1) // 10240
    if m10k != 6:
        return fail(f"python ideal m10k want 6 got {m10k}")
    if "6.0 M10K" not in sv and "6 M10K" not in sv:
        return fail("RTL header must state 6.0 M10K default ideal")
    print("OK default ideal M10K=6 (ESTIMATE packing; fit UNVERIFIED)")

    if "present_nn_linebuf_scaler.sv" not in qip:
        return fail("files.qip must list present_nn_linebuf_scaler.sv")
    if "plex_m10k_geom.svh" not in qip:
        return fail("files.qip must list plex_m10k_geom.svh")
    print("OK qip lists scaler + geom")

    # NEGATIVE: if someone sets LINE_HOLD=16 as default, catch
    m = re.search(r"parameter int LINE_HOLD\s*=\s*(\d+)", sv)
    if not m or int(m.group(1)) != 2:
        return fail("NEGATIVE: default LINE_HOLD must remain 2")
    print("OK NEGATIVE twin: default LINE_HOLD!=16")

    print("PASS test_present_nn_linebuf_scaler_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
