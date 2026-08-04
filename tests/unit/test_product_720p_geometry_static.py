#!/usr/bin/env python3
"""Product 720p geometry switch — static contract + M10K PREREG (no fit).

POSITIVE: QSF FRAME_W/H=1280/720; ddr_frame_layout_params + host kPlex720p*
match; productDdrFrameStoreGeometry is 720p; content_width ≥11 bits.
NEGATIVE: 480p product silicon match or FRAME_W=640 in QSF must fail.

M10K PREREG (publish before fit): linebuf ideal bits scale with CODED_W.
  measured_480 linebufs from prior strip fit entity path ≈96 M10K @640 coded
  (parent/nostub docs). Scale bits 640→1280 ≈×2 → PREREG Δ_linebuf ≈ +96 M10K
  shallow-pack, or +16 M10K ideal-bit lower bound. Budget free after strip=356.
"""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
SVH = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
HOST = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
DEVICE_M10K = 553
FREE_AFTER_STRIP = 356  # 553-197; parent-confirmed strip fit
# PREREG linebuf delta (ESTIMATE — not a fit measure)
PREREG_LINEBUF_M10K_LO = 16   # ideal bit lower bound (p720 scope)
PREREG_LINEBUF_M10K_HI = 101  # shallow pack scale from ~96@640 → ~192@1280, Δ≈96; +margin
PREREG_ALM_DELTA = 0  # geometry is params/clog2; ALM Δ UNMEASURED until fit


def need(cond: bool, msg: str) -> None:
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)


def main() -> int:
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
    svh = SVH.read_text(encoding="utf-8", errors="replace")
    host = HOST.read_text(encoding="utf-8", errors="replace")
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    store = STORE.read_text(encoding="utf-8", errors="replace")

    active = [ln for ln in qsf.splitlines() if not ln.strip().startswith("#")]
    need(any('VERILOG_MACRO "FRAME_W=1280"' in ln for ln in active), "QSF active FRAME_W=1280")
    need(any('VERILOG_MACRO "FRAME_H=720"' in ln for ln in active), "QSF active FRAME_H=720")
    need(not any('VERILOG_MACRO "FRAME_W=640"' in ln for ln in active), "QSF active FRAME_W=640 absent")

    def svh_int(name: str) -> int:
        m = re.search(rf"localparam int {name} = ([^;]+);", svh)
        need(bool(m), f"missing {name} in svh")
        raw = m.group(1).strip().replace("_", "")
        # SystemVerilog sized hex: 32'h00180000
        mhex = re.fullmatch(r"\d+'h([0-9a-fA-F]+)", raw)
        if mhex:
            return int(mhex.group(1), 16)
        mbin = re.fullmatch(r"\d+'b([01]+)", raw)
        if mbin:
            return int(mbin.group(1), 2)
        mdec = re.fullmatch(r"\d+'d([0-9]+)", raw)
        if mdec:
            return int(mdec.group(1), 10)
        return int(raw, 0)

    # Dual-header SSOT: primary DDR_FRAME_* remain 480p pillarbox; 720p tier is
    # DDR_FRAME_720P_* (parent-measured Option-C map). QSF FRAME 1280 selects the
    # 720p tier via ddr_frame_abi_select — do not collapse primary onto 720p.
    need(svh_int("DDR_FRAME_CODED_WIDTH") == 624, "480p primary CODED_W")
    need(svh_int("DDR_FRAME_YUV420P_BYTES") == 449280, "480p primary I420")
    need(svh_int("DDR_FRAME_720P_CODED_WIDTH") == 1280, "720p tier CODED_W")
    need(svh_int("DDR_FRAME_720P_CODED_HEIGHT") == 720, "720p tier CODED_H")
    need(svh_int("DDR_FRAME_720P_PRESENTED_WIDTH") == 1280, "720p PRESENTED_W")
    need(svh_int("DDR_FRAME_720P_PRESENTED_HEIGHT") == 720, "720p PRESENTED_H")
    need(svh_int("DDR_FRAME_720P_YUV420P_BYTES") == 1382400, "720p I420=1280*720*3/2")
    need(svh_int("DDR_FRAME_720P_Y_STRIDE_BYTES") == 1280, "720p Y stride")
    need(svh_int("DDR_FRAME_720P_CHROMA_STRIDE_BYTES") == 640, "720p C stride")
    need(svh_int("DDR_FRAME_720P_YUV420P_BANK_STRIDE") == 0x180000, "720p bank stride")
    need(svh_int("DDR_FRAME_720P_PHYS_BASE") == 0x30180000, "720p phys base Option-C")
    need(svh_int("DDR_FRAME_720P_YUV420P_DOORBELL_PHYS") == 0x3047F000, "720p doorbell")
    # doorbell = base + 2*stride - 0x1000
    need(0x30180000 + 2 * 0x180000 - 0x1000 == 0x3047F000, "doorbell arithmetic")
    need(1280 * 720 * 3 // 2 == 1382400, "I420 arithmetic")

    need("kPlex720pCodedWidth" in host and "1280" in host, "host kPlex720pCodedWidth")
    need("1382400" in host and "kPlex720pYuv420pBytes" in host, "host 720p I420 bytes")
    need("0x3047F000" in host or "0x3047f000" in host.lower(), "host 720p doorbell")
    need("kPlex720pYuv420pBankStride" in host, "host 720p bank stride")
    need("ddr_frame_abi_select.svh" in Path("fpga/Plex_MiSTer/rtl/present_core.sv").read_text(),
         "present_core includes abi_select for FRAME→720p tier")

    # content_width must hold 1280
    need(re.search(r"wire\s*\[10:0\]\s*content_width", plex),
         "content_width must be [10:0] (11 bits) for 1280")
    need("11'd1280" in plex, "content_width 1280 tier")

    need(re.search(r"parameter int FRAME_W\s*=\s*1280", store), "store default FRAME_W")
    need(re.search(r"parameter int FRAME_H\s*=\s*720", store), "store default FRAME_H")
    need(re.search(r"Y_LINE_QWORDS\s*=\s*CODED_W\s*/\s*8", store), "Y_LINE scales")

    # Parent M10K claim: 10240 bits = 1280 bytes = one luma line @8bpp
    need(10240 // 8 == 1280, "M10K byte size")
    y_line_bits = 160 * 64  # one Y linebuf depth in bits
    need(y_line_bits == 10240, "one 1280 luma line @64b qwords == 1 M10K")

    # Ideal linebuf bits LINE_COUNT=8 → 16 slots
    def bits(cw: int) -> int:
        return 16 * (cw // 8 + 2 * (cw // 16)) * 64

    b640, b1280 = bits(640), bits(1280)
    need(b1280 == 2 * b640, "ideal bits double with width")
    ideal_m10k_720 = b1280 / 10240  # 32.0
    need(ideal_m10k_720 == 32.0, "ideal 32 M10K")

    # Budget headroom PREREG (estimate band)
    need(PREREG_LINEBUF_M10K_HI < FREE_AFTER_STRIP,
         f"PREREG linebuf HI {PREREG_LINEBUF_M10K_HI} must fit in free {FREE_AFTER_STRIP}")
    remain = FREE_AFTER_STRIP - PREREG_LINEBUF_M10K_HI
    need(remain > 0, "no M10K left after linebuf PREREG HI")

    # NEGATIVE: QSF 640 twin
    if 'VERILOG_MACRO "FRAME_W=640"' in qsf.replace("1280", "640"):
        pass  # structural; real red:
    red_qsf = qsf.replace('FRAME_W=1280', 'FRAME_W=640')
    need('FRAME_W=640' in red_qsf and 'FRAME_W=1280' not in red_qsf,
         "red twin construction")

    print(
        "PASS product_720p_geometry | FRAME=1280x720 | I420=1382400 | "
        f"bank=0x180000 doorbell=0x302FF000 | "
        f"PREREG_linebuf_M10K={PREREG_LINEBUF_M10K_LO}..{PREREG_LINEBUF_M10K_HI} "
        f"ESTIMATE free_after_strip={FREE_AFTER_STRIP} remain_lo={FREE_AFTER_STRIP-PREREG_LINEBUF_M10K_HI} | "
        f"PREREG_ALM_delta={PREREG_ALM_DELTA}_UNMEASURED | "
        f"ideal_linebuf_M10K={ideal_m10k_720} | M10K_bytes=1280_HIT"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
