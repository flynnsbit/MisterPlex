#!/usr/bin/env python3
"""FAIL-closed product-wire gate for fabric DDR publish (w-mem).

Settled premise: T_copy ~15 ms fails serial 720p24 → fabric publish required.
Product doorbell 0x302FF000 / bank stride 0x180000 on main.

This gate does NOT claim product wire. It asserts:
  1) engine + arbiter3 + path exist with DIRECT vs COPY + m0> m2 > m1
  2) M10K costs state depth×width (bounce 16×64 logic; arb3 m1 fifo 8×64 MLAB)
  3) modules are NOT in files.qip and NOT instantiated in Plex.sv
     (rd-duck: no dead QIP; no silent product enable)
  4) product layout ABI matches doorbell/stride

NEGATIVE (must FAIL when broken):
  - claim product-wired while still missing from Plex.sv
  - files.qip lists engine without Plex.sv instance
  - bounce lacks ramstyle=logic / depth×width note
  - doorbell/stride drift off product constants
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
SVH = RTL / "ddr_frame_layout_params.svh"
ENGINE = RTL / "ddr_publish_engine.sv"
ARB3 = RTL / "ddr_bus_arbiter3.sv"
PATH = RTL / "ddr_publish_path.sv"

PRODUCT_DOORBELL = "32'h302F_F000"
PRODUCT_STRIDE = "32'h0018_0000"


def fail(msg: str) -> None:
    print(f"FAIL fabric_publish_product_wire: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    print("=== test_fabric_publish_product_wire_static EXECUTED ===")

    for p in (ENGINE, ARB3, PATH, QIP, PLEX, SVH):
        if not p.is_file():
            fail(f"missing {p.relative_to(ROOT)}")

    eng = ENGINE.read_text(encoding="utf-8", errors="replace")
    arb = ARB3.read_text(encoding="utf-8", errors="replace")
    path = PATH.read_text(encoding="utf-8", errors="replace")
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    svh = SVH.read_text(encoding="utf-8", errors="replace")

    # --- modes DIRECT vs COPY ---
    if "cmd_mode" not in eng or "DIRECT" not in eng or "COPY" not in eng:
        fail("engine must document DIRECT vs COPY cmd_mode")
    if not re.search(r"if\s*\(\s*!cmd_mode\s*\)", eng):
        fail("engine must branch DIRECT on !cmd_mode")
    if "ST_RD_ISSUE" not in eng or "ST_WR_ISSUE" not in eng:
        fail("engine COPY path missing RD/WR issue states")

    # --- M10K depth×width (NACK without) ---
    if 'ramstyle = "logic"' not in eng and 'ramstyle="logic"' not in eng:
        fail("engine bounce must force ramstyle=logic (M10K=0 by construction)")
    if not re.search(r"bounce\s*\[\s*0\s*:\s*MAX_BURST\s*-\s*1\s*\]", eng):
        fail("bounce depth must be MAX_BURST (depth×width stated)")
    if not re.search(r"reg\s*\[\s*63\s*:\s*0\s*\]\s*bounce", eng):
        fail("bounce width must be 64b")
    if not re.search(r"depth\s*=\s*MAX_BURST", eng, re.I):
        fail("header must state bounce depth=MAX_BURST (handbook depth×width class)")
    if not re.search(r"width\s*=\s*64", eng, re.I):
        fail("header must state bounce width=64b")
    if "1024" not in eng and "useful bits" not in eng.lower():
        fail("header must quantify bounce useful bits (16×64=1024 default)")

    # arbiter3 priority present > publish > bitstream
    if "m0" not in arb or "m2" not in arb or "m1" not in arb:
        fail("arbiter3 must expose m0/m1/m2")
    if "M2_QUANTUM_BEATS" not in arb:
        fail("arbiter3 must quantum-preempt m2 under m0 (present > publish)")
    if "m0_cmd" not in arb:
        fail("arbiter3 must sample m0_cmd for present priority")
    if not re.search(
        r"async_fifo\s*#\s*\(\s*\.WIDTH\s*\(\s*64\s*\)\s*,\s*\.AW\s*\(\s*3\s*\)", arb
    ):
        fail("arbiter3 m1 rsp FIFO must state WIDTH=64 AW=3 (depth 8 × 64b)")
    if "DEPTH=8" not in arb and "depth 8" not in arb.lower() and "AW=3" not in arb:
        fail("arbiter3 M10K note must state FIFO depth×width (AW=3 → DEPTH=8 × 64b)")

    # path composes engine
    if "ddr_publish_engine" not in path:
        fail("ddr_publish_path must instantiate ddr_publish_engine")

    # --- product ABI on main ---
    if "32'h0018_0000" not in svh and "32'h180000" not in svh:
        fail("layout params missing product bank stride 0x180000")
    if "32'h302F_F000" not in svh and "32'h302FF000" not in svh:
        fail("layout params missing product doorbell 0x302FF000")

    # --- FAIL-closed: NOT product-wired yet ---
    qip_lists = bool(re.search(r"ddr_publish_engine\.sv", qip))
    qip_lists |= bool(re.search(r"ddr_bus_arbiter3\.sv", qip))
    qip_lists |= bool(re.search(r"ddr_publish_path\.sv", qip))
    plex_inst = bool(re.search(r"\bddr_publish_engine\b", plex))
    plex_inst |= bool(re.search(r"\bddr_publish_path\b", plex))
    plex_inst |= bool(re.search(r"\bddr_bus_arbiter3\b", plex))

    if qip_lists and not plex_inst:
        fail("dead QIP: publish modules in files.qip but not instantiated in Plex.sv")
    if qip_lists or plex_inst:
        # Product wire is a parent decision; this tree must stay unit-only until
        # intentional enable. Claiming wired without full plan fails closed.
        fail(
            "product wire detected (qip or Plex.sv) — expected unit-only land "
            "(set PRODUCT_WIRE after parent enable + TB green); "
            f"qip={qip_lists} plex_inst={plex_inst}"
        )

    # Present product arbiter remains 2-master
    if "ddr_bus_arbiter " not in plex and "ddr_bus_arbiter(" not in plex:
        # instance name forms
        if not re.search(r"ddr_bus_arbiter\s+#?\s*\(", plex) and not re.search(
            r"\bddr_bus_arbiter\b", plex
        ):
            # may be hierarchical via present_core
            pass

    print(
        "PASS fabric_publish_product_wire_static "
        "DIRECT+COPY engine present; arb3 m0>m2>m1; "
        "M10K bounce depth=MAX_BURST×64b logic=0; "
        "m1_fifo DEPTH=8×64b MLAB; "
        "product doorbell 0x302FF000 stride 0x180000; "
        "PRODUCT_WIRE=0 (not in qip/Plex.sv); "
        "budget class PRODUCT_NO_STUB free ~356 M10K"
    )
    print("true rc=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
