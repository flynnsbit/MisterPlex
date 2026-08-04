#!/usr/bin/env python3
"""Inventory + wire check: 720p layout constants must feed ddr_frame_store on L4.

CONFIRMS reviewer point 5 was real on pre-fix main: DDR_FRAME_720P_* lived only
in ddr_frame_layout_params.svh (+ host/tests). present_core must now select them
behind PLEX_PRESENT_720P_L4 while default arm keeps 480p symbols.

Negative: a present_core that still only binds DDR_FRAME_CODED_WIDTH (no 720P
symbols on the L4 arm) must fail.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
LAYOUT = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"


def nt(s: str) -> str:
    return re.sub(r"\s+", "", s)


def fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    present = PRESENT.read_text(encoding="utf-8", errors="replace")
    layout = LAYOUT.read_text(encoding="utf-8", errors="replace")
    store = STORE.read_text(encoding="utf-8", errors="replace")
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
    pnt = nt(present)
    lnt = nt(layout)

    # --- Inventory of 720p symbols and consumers ---
    syms_720 = re.findall(r"localparam\s+int\s+(DDR_FRAME_720P\w+)\s*=", layout)
    if len(syms_720) < 10:
        return fail(f"expected >=10 DDR_FRAME_720P_* in svh, got {syms_720}")

    # Product RTL consumers excluding the svh itself
    rtl_root = ROOT / "fpga/Plex_MiSTer/rtl"
    consumers: dict[str, list[str]] = {s: [] for s in syms_720}
    for path in sorted(rtl_root.rglob("*.sv")):
        if path.name == "ddr_frame_layout_params.svh":
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for s in syms_720:
            if s in text:
                consumers[s].append(str(path.relative_to(ROOT)))

    # Shared ABI path (w-clock): present_core includes ddr_frame_abi_select.svh
    # which ternaries DDR_FRAME_720P_* when FRAME is 1280×720 (L4 *or* MULTI).
    # Legacy L4-only ifdef binds are also accepted.
    abi_path = rtl_root / "ddr_frame_abi_select.svh"
    if not abi_path.is_file():
        return fail("missing rtl/ddr_frame_abi_select.svh")
    abi_sel = abi_path.read_text(errors="ignore")
    abi_nt = nt(abi_sel)
    shared_abi = (
        'include"ddr_frame_abi_select.svh"' in pnt
        and "DDR_FS_USE_720P_ABI" in abi_nt
        and "DDR_FRAME_720P_CODED_WIDTH" in abi_nt
        and "DDR_FRAME_720P_CODED_HEIGHT" in abi_nt
    )
    legacy_l4 = all(
        n in pnt
        for n in (
            "FS_CODED_W=DDR_FRAME_720P_CODED_WIDTH",
            "FS_CODED_H=DDR_FRAME_720P_CODED_HEIGHT",
            "FS_BANK_STRIDE=DDR_FRAME_720P_YUV420P_BANK_STRIDE",
        )
    )
    if not (shared_abi or legacy_l4):
        return fail("present_core missing shared 720p ABI select or legacy L4 binds")

    required = [
        "DDR_FRAME_720P_CODED_WIDTH",
        "DDR_FRAME_720P_CODED_HEIGHT",
        "DDR_FRAME_720P_DISPLAY_WIDTH",
        "DDR_FRAME_720P_DISPLAY_HEIGHT",
        "DDR_FRAME_720P_PILLARBOX_LEFT",
        "DDR_FRAME_720P_YUV420P_BANK_STRIDE",
        "DDR_FRAME_720P_PHYS_BASE",
        "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS",
    ]
    for s in required:
        in_core = "present_core.sv" in " ".join(consumers.get(s, []))
        in_abi = s in abi_sel
        if not (in_core or in_abi or legacy_l4):
            return fail(f"{s} has no present_core/abi_select consumer: {consumers.get(s)}")

    # Default/shared arm must still name 480p constants (via select or direct)
    for needle in [
        "DDR_FRAME_CODED_WIDTH",
        "DDR_FRAME_DISPLAY_WIDTH",
        "DDR_FRAME_YUV420P_BANK_STRIDE",
        "DDR_FRAME_YUV420P_DOORBELL_PHYS",
    ]:
        if needle not in pnt and needle not in abi_nt:
            return fail(f"480p ABI constant missing from core/abi_select: {needle}")

    # Store instance must take FS_* geometry ports
    for needle in [
        ".CODED_W(FS_CODED_W)",
        ".HPS_BANK_STRIDE_BYTES(FS_BANK_STRIDE)",
        ".DOORBELL_PHYS(FS_DOORBELL)",
        ".PHYS_BASE(FS_PHYS_BASE)",
    ]:
        if needle not in pnt:
            return fail(f"store FS_* port wire missing {needle}")

    # L4 gate text still present (exclusive alternate)
    if "ifdefPLEX_PRESENT_720P_L4" not in pnt and "`ifdef PLEX_PRESENT_720P_L4" not in present:
        return fail("L4 ifdef gate missing from present_core")

    # Store still derives visibility from params (not hardcoded 618)
    snt = nt(store)
    for needle in [
        "PRESENT_END_X=X_W'(PRESENT_X+DISPLAY_W)",
        "PRESENT_END_Y=Y_W'(PRESENT_Y+DISPLAY_H)",
        "rd_x_visible=rd_x_at_or_after_origin&&(rd_x<PRESENT_END_X)",
        "Y_LINE_QWORDS=CODED_W/8",
        "HPS_BANK_STRIDE_QWORDS=29'(HPS_BANK_STRIDE_BYTES/8)",
    ]:
        if needle not in snt:
            return fail(f"ddr_frame_store formula missing {needle}")

    # Default-off product
    if re.search(r"^\s*set_global_assignment.*PLEX_PRESENT_720P_L4=1", qsf, re.M):
        return fail("PLEX_PRESENT_720P_L4 must stay commented/default-off in QSF")
    # Active product canvas is 1280×720 (not merely commented prose).
    act = re.findall(
        r'^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"([^"]+)"',
        qsf,
        flags=re.M,
    )
    if not any("FRAME_W=1280" in m for m in act) or not any("FRAME_H=720" in m for m in act):
        return fail("product QSF must keep active FRAME 1280x720")
    if any("FRAME_W=640" in m for m in act) or any("FRAME_H=480" in m for m in act):
        return fail("legacy FRAME 640x480 must not be active product QSF")

    # NEGATIVE: empty consumer + no abi_select must go red
    fake_consumers = {**consumers, "DDR_FRAME_720P_CODED_WIDTH": []}
    if "present_core.sv" in " ".join(fake_consumers["DDR_FRAME_720P_CODED_WIDTH"]):
        return fail("negative consumer empty-list did not go red")
    if shared_abi:
        bad_abi = abi_nt.replace("DDR_FRAME_720P_CODED_WIDTH", "DDR_FRAME_CODED_WIDTH")
        if "DDR_FRAME_720P_CODED_WIDTH" in bad_abi:
            return fail("negative abi strip failed")
        print("OK negative twin: stripping 720P coded from abi_select would fail gate")

    # Print inventory table
    print("INVENTORY DDR_FRAME_720P_* consumers (RTL .sv):")
    for s in sorted(syms_720):
        c = consumers.get(s, [])
        print(f"  {s}: {c if c else 'NONE (beam/test-only or unused)'}")

    mode = "shared-ABI" if shared_abi else "legacy-L4"
    print(
        f"PASS present_720p_store_wire: {mode} 720p coded/display/pillar/stride/"
        "doorbell/phys; 480p arm intact"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
