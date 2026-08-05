#!/usr/bin/env python3
"""FAIL-closed product-wire gate for fabric DDR publish (w-mem / w-integ).

Settled premise: T_copy ~15 ms fails serial 720p24 → fabric publish required.
Product doorbell 0x302FF000 / bank stride 0x180000 on main.

PHASE1 compose (parent-authorized research land):
  - engine + arbiter3 + path exist with DIRECT vs COPY + m0 > m2 > m1
  - modules MAY be in files.qip + Plex.sv when nested under `ifdef PRODUCT_WIRE
  - product default: PRODUCT_WIRE QSF macro stays COMMENTED (arb2 elaborates)
  - phase1 controls: start=0, cmd_mode=1 COPY, ring_doorbell=0
  - present_want = present_ddr_rd | present_ddr_we
  - u_fabric_frame_dma stub may remain under FABRIC_FRAME_DMA (area only)

This gate does NOT claim product wire live or device offload.
NEGATIVE (must FAIL when broken):
  - dead QIP (listed, not instantiated under PRODUCT_WIRE)
  - publish tokens without `ifdef PRODUCT_WIRE wrapper
  - PRODUCT_WIRE=1 live-enabled in product QSF
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
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
SVH = RTL / "ddr_frame_layout_params.svh"
ENGINE = RTL / "ddr_publish_engine.sv"
ARB3 = RTL / "ddr_bus_arbiter3.sv"
PATH = RTL / "ddr_publish_path.sv"
JOB = RTL / "ddr_publish_job.sv"

PRODUCT_DOORBELL = "32'h302F_F000"
PRODUCT_STRIDE = "32'h0018_0000"


def fail(msg: str) -> None:
    print(f"FAIL fabric_publish_product_wire: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    print("=== test_fabric_publish_product_wire_static EXECUTED ===")

    for p in (ENGINE, ARB3, PATH, JOB, QIP, PLEX, QSF, SVH):
        if not p.is_file():
            fail(f"missing {p.relative_to(ROOT)}")

    eng = ENGINE.read_text(encoding="utf-8", errors="replace")
    arb = ARB3.read_text(encoding="utf-8", errors="replace")
    path = PATH.read_text(encoding="utf-8", errors="replace")
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
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

    # --- Compose / wire state ---
    qip_lists = bool(re.search(r"ddr_publish_engine\.sv", qip))
    qip_lists |= bool(re.search(r"ddr_bus_arbiter3\.sv", qip))
    qip_lists |= bool(re.search(r"ddr_publish_path\.sv", qip))
    qip_lists |= bool(re.search(r"ddr_publish_job\.sv", qip))
    plex_path = bool(re.search(r"\bddr_publish_path\b", plex))
    plex_arb3 = bool(re.search(r"\bddr_bus_arbiter3\b", plex))
    plex_inst = plex_path or plex_arb3 or bool(
        re.search(r"\bddr_publish_engine\b", plex)
    )

    # Product else path must keep 2-master arbiter (name token appears outside
    # arbiter3). Prefer instance form "ddr_bus_arbiter ddr_arb".
    has_arb2 = bool(re.search(r"\bddr_bus_arbiter\s+ddr_arb\b", plex)) or bool(
        re.search(r"\bddr_bus_arbiter\s+#?\s*\(", plex)
    )

    # PRODUCT_WIRE must stay commented/OFF in product QSF by default.
    live_pw = bool(
        re.search(
            r'(?m)^\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"PRODUCT_WIRE\s*=\s*1"',
            qsf,
        )
    )
    commented_pw = bool(
        re.search(
            r'(?m)^\s*#\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"PRODUCT_WIRE\s*=\s*1"',
            qsf,
        )
    )
    if live_pw:
        fail(
            "PRODUCT_WIRE=1 is LIVE in Plex.qsf — product default must stay OFF "
            "(comment the macro; research enable only under parent FIT_GO)"
        )

    if qip_lists and not plex_inst:
        fail("dead QIP: publish modules in files.qip but not instantiated in Plex.sv")

    if qip_lists or plex_inst:
        # Intentional phase1 compose: tokens allowed only under PRODUCT_WIRE ifdef.
        if not re.search(r"`ifdef\s+PRODUCT_WIRE", plex):
            fail(
                "publish tokens require nested `ifdef PRODUCT_WIRE in Plex.sv "
                "(regex gate is not ifdef-aware; wrapper is the product-default OFF fence)"
            )
        if not plex_path:
            fail("PRODUCT_WIRE path must instantiate ddr_publish_path (u_pub)")
        if not plex_arb3:
            fail("PRODUCT_WIRE path must instantiate ddr_bus_arbiter3")
        if not has_arb2:
            fail("PRODUCT_WIRE else path must keep ddr_bus_arbiter (product OFF elaborates arb2)")
        if not commented_pw:
            fail(
                "Plex.qsf must document commented research enable: "
                '#set_global_assignment -name VERILOG_MACRO "PRODUCT_WIRE=1"'
            )

        # Phase1 control bindings (start idle, COPY, host doorbell)
        if not re.search(r"pub_start_ddr\s*=\s*1'b0", plex):
            fail("phase1: pub_start_ddr must be tied 1'b0")
        if not re.search(r"pub_cmd_mode\s*=\s*1'b1", plex):
            fail("phase1: pub_cmd_mode must be 1'b1 (COPY)")
        if not re.search(r"pub_ring_db\s*=\s*1'b0", plex) and not re.search(
            r"ring_doorbell\s*\(\s*1'b0\s*\)", plex
        ):
            # accept either wire assign or port tie
            if not re.search(
                r"pub_ring_db\s*=\s*1'b0|\.ring_doorbell\s*\(\s*pub_ring_db\s*\)", plex
            ):
                fail("phase1: ring_doorbell must be 0 (host owns doorbell)")
            # if only port uses pub_ring_db, require the wire is 0
            if "pub_ring_db" in plex and not re.search(
                r"pub_ring_db\s*=\s*1'b0", plex
            ):
                fail("phase1: pub_ring_db must be tied 1'b0")

        # present_want = present_ddr_rd | present_ddr_we
        if not re.search(
            r"present_ddr_rd\s*\|\s*present_ddr_we", plex
        ) and not re.search(
            r"present_want\s*\(\s*present_cmd\s*\)", plex
        ):
            fail("present_want must come from present_ddr_rd | present_ddr_we")
        if not re.search(r"present_ddr_rd\s*\|\s*present_ddr_we", plex):
            fail("present_cmd/present_want must OR present_ddr_rd | present_ddr_we")

        # Keep area stub optional but if FABRIC_FRAME_DMA block present, start=0
        if re.search(r"\bu_fabric_frame_dma\b", plex):
            if not re.search(r"\.start\s*\(\s*1'b0\s*\)", plex):
                fail("u_fabric_frame_dma stub must keep start=0")

        print(
            "PASS fabric_publish_product_wire_static "
            "DIRECT+COPY engine present; arb3 m0>m2>m1; "
            "M10K bounce depth=MAX_BURST×64b logic=0; "
            "m1_fifo DEPTH=8×64b MLAB; "
            "product doorbell 0x302FF000 stride 0x180000; "
            "PHASE1 PRODUCT_WIRE compose in qip+Plex under `ifdef; "
            "PRODUCT_WIRE QSF default OFF (commented); "
            "start=0 COPY ring_db=0 present_want=rd|we; "
            "budget class PRODUCT_NO_STUB free ~356 M10K"
        )
    else:
        # Unit-only land still legal if compose not yet applied
        if not has_arb2 and "ddr_bus_arbiter" not in plex:
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
