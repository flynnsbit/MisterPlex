#!/usr/bin/env python3
"""Static gate: fabric DMA ARM kick composed into integ/720p-compose.

POS: fabric_dma_arm_kick + Option-C phys defaults + qip + FABRIC_FRAME_DMA.
NEG: start must not be hardwired 1'b1 (would thrash DMA on reset); kick held 0.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def fail(msg: str) -> int:
    print(f"FAIL {msg}", file=sys.stderr)
    return 1


def main() -> int:
    print("CASE fabric_dma_compose_static EXECUTED")
    print("PRE_REGISTER: u_fabric_dma_arm_kick present; kick=0; bank=0x30180000; src=0x30601000")
    print("M10K arm_kick=0 (regs); bounce EST=2 layout=2x(256x32) unfitted")
    print("REFRESH: not claimed by this gate (w-clock PLL)")

    plex = (ROOT / "fpga/Plex_MiSTer/Plex.sv").read_text(encoding="utf-8", errors="replace")
    qip = (ROOT / "fpga/Plex_MiSTer/files.qip").read_text(encoding="utf-8", errors="replace")
    qsf = (ROOT / "fpga/Plex_MiSTer/Plex.qsf").read_text(encoding="utf-8", errors="replace")
    kick_sv = ROOT / "fpga/Plex_MiSTer/rtl/fabric_dma_arm_kick.sv"
    kick_hpp = ROOT / "host/libmisterplex/fabric_dma_kick.hpp"

    if not kick_sv.is_file():
        return fail("missing fabric_dma_arm_kick.sv")
    if not kick_hpp.is_file():
        return fail("missing fabric_dma_kick.hpp")
    if "fabric_dma_arm_kick.sv" not in qip:
        return fail("files.qip missing fabric_dma_arm_kick.sv")
    if "FABRIC_FRAME_DMA=1" not in qsf and 'VERILOG_MACRO "FABRIC_FRAME_DMA=1"' not in qsf:
        return fail("Plex.qsf must enable FABRIC_FRAME_DMA on compose")
    if "FRAME_W=1280" not in qsf:
        return fail("compose QSF must set FRAME_W=1280")
    if "u_fabric_dma_arm_kick" not in plex:
        return fail("Plex.sv missing u_fabric_dma_arm_kick instance")
    if "u_fabric_frame_dma" not in plex:
        return fail("Plex.sv missing u_fabric_frame_dma")
    if not re.search(r"\.kick\(\s*1'b0\s*\)", plex):
        return fail("NEG: arm kick must be held 1'b0 until HPS wire (got free kick)")
    if re.search(r"\.start\(\s*1'b1\s*\)", plex):
        return fail("NEG: dma start must not be hardwired 1'b1")
    if "32'h3018_0000" not in plex and "32'h30180000" not in plex:
        return fail("Option-C bank0 phys 0x30180000 not composed")
    if "32'h3060_1000" not in plex and "32'h30601000" not in plex:
        return fail("PL330 staging src 0x30601000 not composed")
    if "1_382_400" not in plex and "1382400" not in plex:
        return fail("720p frame_bytes 1382400 not composed")

    sv = kick_sv.read_text(encoding="utf-8", errors="replace")
    if "M10K: 0" not in sv:
        return fail("arm_kick.sv must state M10K: 0")
    if "module fabric_dma_arm_kick" not in sv:
        return fail("module name missing")

    hpp = kick_hpp.read_text(encoding="utf-8", errors="replace")
    if "buildFabricDmaKick720p" not in hpp:
        return fail("host kick builder missing")
    if "M10K: 0" not in hpp:
        return fail("host kick must state M10K: 0")

    print("PASS fabric_dma_compose_static Option-C defaults + kick held 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
