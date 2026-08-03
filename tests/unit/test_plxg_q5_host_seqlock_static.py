#!/usr/bin/env python3
"""PLXG q5 host publish must be one 6-qword seqlock — never standalone +0x828.

rd-duck BLOCKING cross-lane collision:
  w-path writePlxgQ5 writes doorbell+0x828 alone and re-applies before kick.
  w-mem writePlxgRecord is q1..q5 then q0/new seq; poller skips body when
  q0 epoch/seq == last. Standalone q5 after committed q0 is never promoted;
  before full record it is overwritten by plan q5=0; concurrent = torn.
  Path addresses active doorbell+0x828; poller is fixed bootstrap 0x300FF800
  so Option-C 0x3047F828 is never read.

Product fix: inject q5 into DdrPublishPlan / writePlxgRecord generation;
delete/refuse standalone product writePlxgQ5.

This gate is red-before-green: presence of writePlxgQ5 as a product API is FAIL.
Fabric q5 wire (w-osd) ≠ host publish correctness.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPI_CPP = ROOT / "arm" / "misterplexd" / "fpga_spi.cpp"
SPI_HPP = ROOT / "arm" / "misterplexd" / "fpga_spi.hpp"


def main() -> int:
    fails = 0
    cpp = SPI_CPP.read_text(encoding="utf-8", errors="replace") if SPI_CPP.is_file() else ""
    hpp = SPI_HPP.read_text(encoding="utf-8", errors="replace") if SPI_HPP.is_file() else ""

    # Standalone product API is forbidden (rd-duck).
    if re.search(r"\bwritePlxgQ5\s*\(", cpp) or re.search(r"\bwritePlxgQ5\s*\(", hpp):
        print(
            "FAIL product writePlxgQ5 present — standalone +0x828 never promotes "
            "under w-mem seqlock/poller; inject q5 into writePlxgRecord instead",
            file=sys.stderr,
        )
        fails += 1
    else:
        print("OK no standalone writePlxgQ5 product API")

    # If full record writer exists, it must touch q5 / six beats / +0x828 in-body.
    if re.search(r"\bwritePlxgRecord\s*\(", cpp) or re.search(r"\bwritePlxgRecord\s*\(", hpp):
        # Body must include index 5 or explicit q5 packing inside the same function region.
        # Heuristic: file must not only write 5 qwords (q[5] array = q0..q4 only).
        if re.search(r"writePlxgRecord\([^)]*q\s*\[\s*5\s*\]", hpp) and not re.search(
            r"q\s*\[\s*6\s*\]|plxg_q\s*\[\s*6\s*\]|wr_idx.*5|qi\s*==\s*5|q5", cpp + hpp
        ):
            print(
                "FAIL writePlxgRecord signature q[5] without q5/six-beat evidence — "
                "ABI #2 needs q0..q5 in one generation",
                file=sys.stderr,
            )
            fails += 1
        else:
            # Softer: require some q5 mention near writePlxgRecord definition
            m = re.search(r"bool\s+FpgaSpi::writePlxgRecord.*?(?=\nbool\s+FpgaSpi::|\Z)", cpp, re.S)
            body = m.group(0) if m else ""
            if body and not re.search(r"q5|0x828|qi\s*==\s*5|for\s*\(.*6", body):
                print(
                    "FAIL writePlxgRecord body has no q5/+0x828/6-beat store — "
                    "DAR/fps will not ride the seqlock",
                    file=sys.stderr,
                )
                fails += 1
            else:
                print("OK writePlxgRecord present with q5/six-beat signal (or not yet on tree)")
    else:
        print("OK writePlxgRecord absent on this tree (fabric q5 wire only; host half open)")

    # Document bootstrap vs Option-C: mailbox ABI must name bootstrap PLXG page.
    abi = ROOT / "host" / "libmisterplex" / "mailbox_abi_spec.hpp"
    if abi.is_file():
        at = abi.read_text(encoding="utf-8", errors="replace")
        if "kPlxgBootstrapPhys" not in at and "0x300FF800" not in at:
            print("FAIL mailbox_abi missing PLXG bootstrap phys (poller page)", file=sys.stderr)
            fails += 1
        else:
            print("OK PLXG bootstrap page named in mailbox_abi")

    if fails:
        print(f"test_plxg_q5_host_seqlock_static: {fails} FAIL(s)", file=sys.stderr)
        return 1
    print("test_plxg_q5_host_seqlock_static: PASS")
    print(
        "NOTE: fabric Plex.sv q5 consumers ≠ live host DAR/fps until writePlxgRecord "
        "carries q5 on bootstrap+Option-C with e2e  nonzero DAR/fps."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
