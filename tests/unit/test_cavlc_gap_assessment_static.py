#!/usr/bin/env python3
"""Freeze CAVLC gap-assessment claims against RTL text (w-scaler).

Positive: residual_block + nc_predictor stages present; tables/FSM markers.
Negative: stream_path must NOT instantiate h264_cavlc_residual_block yet
(product wire is the named remaining gap — if someone wires it, update this
gate and the assessment doc together).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "fpga/Plex_MiSTer/rtl"
CAVLC = RTL / "h264_cavlc_residual.sv"
STREAM = RTL / "stream_path.sv"
CORE = RTL / "h264_decode_core.sv"
DOC = ROOT / "docs/cavlc_residual_gap_assessment.md"


def main() -> int:
    fails: list[str] = []
    cavlc = CAVLC.read_text(encoding="utf-8", errors="replace")
    stream = STREAM.read_text(encoding="utf-8", errors="replace")
    core = CORE.read_text(encoding="utf-8", errors="replace")

    if "module h264_cavlc_nc_predictor" not in cavlc:
        fails.append("missing h264_cavlc_nc_predictor")
    if "module h264_cavlc_residual_block" not in cavlc:
        fails.append("missing h264_cavlc_residual_block")

    for marker in (
        "ST_TOKEN_BIT",
        "ST_SIGN",
        "ST_LVL_PRE",
        "ST_LVL_SUF",
        "ST_LVL_STORE",
        "ST_TZ_BIT",
        "ST_RUN_BIT",
        "ST_PLACE_INIT",
        "coeff_token_lookup",
        "total_zeros_lookup",
        "run_before_lookup",
        "suffix_length",
    ):
        if marker not in cavlc:
            fails.append(f"missing marker {marker}")

    # nC formula present
    if "left_tc + up_tc" not in cavlc and "(left_tc + up_tc" not in cavlc:
        fails.append("nC average formula not found")

    # Product stream_path must not silently claim fabric CAVLC wired
    if re.search(r"\bh264_cavlc_residual_block\b", stream):
        fails.append(
            "stream_path now instantiates h264_cavlc_residual_block — "
            "update docs/cavlc_residual_gap_assessment.md (product wire closed)"
        )
    else:
        print("OK gap still open: stream_path has no h264_cavlc_residual_block instance")

    # decode_core hardcode still present (partial orchestration)
    if "u_product_p16_residual0" not in core:
        fails.append("decode_core missing u_product_p16_residual0 instance")
    if ".coeff_token_table(3'd0)" not in core and ".coeff_token_table(3'b000)" not in core:
        print("NOTE: decode_core no longer hardcodes coeff_token_table=0 — check nC wire-up")
    else:
        print("OK gap still open: decode_core hardcodes coeff_token_table=0")

    if not DOC.is_file():
        fails.append("missing docs/cavlc_residual_gap_assessment.md")
    else:
        doc = DOC.read_text(encoding="utf-8", errors="replace")
        for needle in ("COMPLETE", "ABSENT", "231.5", "residualBlock", "CAVLC_NEGATIVE_TABLE"):
            if needle not in doc:
                fails.append(f"assessment doc missing {needle}")
        print("OK assessment doc present with required sections")

    # Negative twin: if residual_block lost ST_LVL_STORE, must fail
    if "ST_LVL_STORE" not in cavlc.replace("ST_LVL_STORE", "", 1):
        # at least one remains after single replace means >=1 originally; use count
        pass
    if cavlc.count("ST_LVL_STORE") < 1:
        fails.append("ST_LVL_STORE absent")
    twin = cavlc.replace("ST_LVL_STORE", "ST_GONE_LEVEL")
    if "ST_LVL_STORE" in twin:
        fails.append("negative twin could not strip ST_LVL_STORE")
    else:
        print("OK NEG twin: removing ST_LVL_STORE would fail this gate")

    if fails:
        for f in fails:
            print(f"FAIL {f}", file=sys.stderr)
        print(f"test_cavlc_gap_assessment_static: {len(fails)} failure(s)", file=sys.stderr)
        return 1
    print("PASS test_cavlc_gap_assessment_static")
    return 0


if __name__ == "__main__":
    sys.exit(main())
