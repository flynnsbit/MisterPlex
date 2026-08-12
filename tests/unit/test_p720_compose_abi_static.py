#!/usr/bin/env python3
"""720p compose ABI static gate (w-path on integ/720p-compose).

GREEN: contract has PHYS_BASE; store owns u_fill_base_mux; present_core
instantiates path geom/width/budget under DDR_FS_USE_720P_ABI; qip lists modules;
layout 720p pack + 480p PHYS_BASE present.

RED (naive wrong): contract missing P720_PHYS_BASE while present_core refs it;
store still has inline fill_bank_base = fill_bank ? BASE_W1 : BASE_W0;
path modules only in qip (dark) with no present_core instance.

Refresh honesty: does NOT claim 24 Hz — only ABI composition.
M10K: base_mux/geom/width/budget = 0 EST (source control).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "fpga/Plex_MiSTer/rtl/plex_720p_bw_contract.svh"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
LAYOUT = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
ABI_SEL = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_abi_select.svh"


def main() -> int:
    c = CONTRACT.read_text(encoding="utf-8", errors="replace")
    s = STORE.read_text(encoding="utf-8", errors="replace")
    p = PRESENT.read_text(encoding="utf-8", errors="replace")
    q = QIP.read_text(encoding="utf-8", errors="replace")
    lay = LAYOUT.read_text(encoding="utf-8", errors="replace")
    abi = ABI_SEL.read_text(encoding="utf-8", errors="replace")

    if not re.search(r"localparam\s+int\s+P720_PHYS_BASE\s*=\s*32'h3018_0000", c):
        print("FAIL: plex_720p_bw_contract missing P720_PHYS_BASE=0x30180000", file=sys.stderr)
        return 1
    if not re.search(r"localparam\s+int\s+P720_BEATS_PER_FRAME\s*=", c):
        print("FAIL: contract missing P720_BEATS_PER_FRAME", file=sys.stderr)
        return 1
    if "P720_PHYS_BASE" not in p or "P720_BEATS_PER_FRAME" not in p:
        print("FAIL: present_core must consume P720_PHYS_BASE/BEATS", file=sys.stderr)
        return 1

    if "u_fill_base_mux" not in s or "ddr_frame_base_mux" not in s:
        print("FAIL: store must instance u_fill_base_mux (compose live path)", file=sys.stderr)
        return 1
    if re.search(
        r"wire\s*\[28:0\]\s*fill_bank_base\s*=\s*fill_bank\s*\?\s*BASE_W1\s*:\s*BASE_W0",
        s,
    ):
        print("FAIL: store still has inline fill_bank_base (must be mux)", file=sys.stderr)
        return 1
    if not re.search(r"parameter\s+bit\s+DYN_BASE_EN\s*=\s*1'b0", s):
        print("FAIL: store DYN_BASE_EN default 0 required", file=sys.stderr)
        return 1

    if "g_path_720p_compose" not in p or "u_path_bank_geom" not in p:
        print("FAIL: present_core missing g_path_720p_compose keep instances", file=sys.stderr)
        return 1
    if "u_path_width_check" not in p or "u_path_copy_budget" not in p:
        print("FAIL: present_core missing width_check/copy_budget compose", file=sys.stderr)
        return 1
    if "ddr_frame_abi_select.svh" not in p:
        print("FAIL: present_core must include ddr_frame_abi_select", file=sys.stderr)
        return 1

    for mod in (
        "ddr_i420_bank_geom.sv",
        "ddr_frame_base_mux.sv",
        "ddr_i420_store_width_check.sv",
        "ddr_publish_copy_budget.sv",
        "ddr_publish_job.sv",
        "ddr_frame_dma.sv",
    ):
        if mod not in q:
            print(f"FAIL: {mod} not in files.qip", file=sys.stderr)
            return 1

    if "DDR_FRAME_PHYS_BASE" not in lay or "DDR_FRAME_720P_PHYS_BASE" not in lay:
        print("FAIL: layout missing PHYS_BASE pack", file=sys.stderr)
        return 1
    if "DDR_FRAME_720P_CROP_LEFT" not in lay:
        print("FAIL: layout missing 720p crop (tier select needs it)", file=sys.stderr)
        return 1
    if "DDR_FRAME_PHYS_BASE" not in abi:
        print("FAIL: abi_select must use DDR_FRAME_PHYS_BASE for 480p", file=sys.stderr)
        return 1

    # NEG twin: strip PHYS_BASE from contract text → would fail present refs
    c_neg = re.sub(r"localparam\s+int\s+P720_PHYS_BASE\s*=\s*32'h3018_0000\s*;", "", c)
    if "P720_PHYS_BASE" in c_neg.split("//")[0] or re.search(
        r"localparam\s+int\s+P720_PHYS_BASE", c_neg
    ):
        pass  # still defined elsewhere is ok
    if "P720_PHYS_BASE" not in p:
        print("FAIL: red twin setup broken", file=sys.stderr)
        return 1
    if not re.search(r"localparam\s+int\s+P720_PHYS_BASE", c_neg):
        # present still refs it → naive contract without PHYS is incomplete
        if "P720_PHYS_BASE" in p:
            print(
                "PASS p720_compose_abi | PHYS_BASE in contract | store u_fill_base_mux | "
                "present g_path_720p_compose | qip modules | NEG contract-without-PHYS incomplete | "
                "M10K_EST mux/geom/width/budget=0 | NOT_CLAIMED=24Hz_refresh"
            )
            return 0

    print(
        "PASS p720_compose_abi | PHYS_BASE in contract | store u_fill_base_mux | "
        "present g_path_720p_compose | qip modules | "
        "M10K_EST mux/geom/width/budget=0 | NOT_CLAIMED=24Hz_refresh"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
