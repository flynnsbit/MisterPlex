#!/usr/bin/env python3
"""Static gate: DIAG_TAG_RCA product default is 0 (product-identical PLXF pack).

DIAG instrument (I1 miss composition + I2 half occupancy) is sole-only via:
  - parameter DIAG_TAG_RCA (default 0), or
  - QSF VERILOG_MACRO MPLEX_DIAG_TAG_RCA=1 (present_core ifdef forces 1)

Product wire must keep default 0 so underrun/debug PLXF pack is unchanged.
DIAG ≠ product residual PASS. PRODUCT_WIRE=0.

POSITIVE:
  - ddr_frame_store + present_core: parameter bit DIAG_TAG_RCA = 1'b0
  - product pack path: else frame_status_ddr <= {frame_underrun_ddr, debug_state}
  - Plex.qsf: MPLEX_DIAG_TAG_RCA assignment is commented (not live product macro)

NEGATIVE:
  - parameter default 1'b1 is RED
  - live (uncommented) set_global_assignment MPLEX_DIAG_TAG_RCA in Plex.qsf is RED
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STORE = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "ddr_frame_store.sv"
PRESENT = ROOT / "fpga" / "Plex_MiSTer" / "rtl" / "present_core.sv"
QSF = ROOT / "fpga" / "Plex_MiSTer" / "Plex.qsf"

PARAM_DEFAULT0 = re.compile(
    r"parameter\s+bit\s+DIAG_TAG_RCA\s*=\s*1'b0\b"
)
PARAM_DEFAULT1 = re.compile(
    r"parameter\s+bit\s+DIAG_TAG_RCA\s*=\s*1'b1\b"
)
# Live (uncommented) QSF macro is forbidden on product tree.
LIVE_QSF_MACRO = re.compile(
    r"(?m)^(?!\s*#)\s*set_global_assignment\s+-name\s+VERILOG_MACRO\s+"
    r'"MPLEX_DIAG_TAG_RCA\s*=\s*1"'
)
PRODUCT_PACK = re.compile(
    r"frame_status_ddr\s*<=\s*\{\s*frame_underrun_ddr\s*,\s*debug_state\s*\}"
)


def fail(msg: str) -> int:
    print(f"FAIL diag_tag_rca_default: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    for p in (STORE, PRESENT, QSF):
        if not p.is_file():
            return fail(f"missing {p}")

    store = STORE.read_text(encoding="utf-8", errors="replace")
    present = PRESENT.read_text(encoding="utf-8", errors="replace")
    qsf = QSF.read_text(encoding="utf-8", errors="replace")

    if not PARAM_DEFAULT0.search(store):
        return fail("ddr_frame_store DIAG_TAG_RCA default must be 1'b0")
    if not PARAM_DEFAULT0.search(present):
        return fail("present_core DIAG_TAG_RCA default must be 1'b0")
    if PARAM_DEFAULT1.search(store) or PARAM_DEFAULT1.search(present):
        return fail("DIAG_TAG_RCA default must not be 1'b1 (product wire)")

    if not PRODUCT_PACK.search(store):
        return fail(
            "product pack path missing: frame_status_ddr <= "
            "{frame_underrun_ddr, debug_state}"
        )
    # DIAG branch must exist (instrument is real) but select only when param=1.
    if not re.search(r"if\s*\(\s*DIAG_TAG_RCA\s*\)", store):
        return fail("DIAG branch if (DIAG_TAG_RCA) missing in ddr_frame_store")

    if "MPLEX_DIAG_TAG_RCA" not in qsf:
        return fail("Plex.qsf must document MPLEX_DIAG_TAG_RCA (commented sole path)")
    if LIVE_QSF_MACRO.search(qsf):
        return fail(
            "Plex.qsf has live MPLEX_DIAG_TAG_RCA=1 — product default requires "
            "commented sole-only macro"
        )

    # present_core must wire ifdef OR param (sole enable path documented).
    if "`ifdef MPLEX_DIAG_TAG_RCA" not in present:
        return fail("present_core must ifdef-wire MPLEX_DIAG_TAG_RCA for sole DIAG")
    if not re.search(r"\.DIAG_TAG_RCA\(\s*DIAG_TAG_RCA\s*\)", present):
        return fail("present_core must pass .DIAG_TAG_RCA(DIAG_TAG_RCA) when macro off")

    print(
        "PASS diag_tag_rca_default:\n"
        "  store+present: parameter DIAG_TAG_RCA = 1'b0\n"
        "  product pack: {frame_underrun_ddr, debug_state} under else\n"
        "  QSF: MPLEX_DIAG_TAG_RCA commented (not live product macro)\n"
        "  present_core: ifdef sole OR param wire\n"
        "  negative: default 1'b1 / live QSF macro are RED"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
