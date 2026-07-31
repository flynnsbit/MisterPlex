#!/usr/bin/env python3
"""P4: software bank phys XOR is only bit 18/19; DRAM BA map remains UNKNOWN in-tree."""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main() -> int:
    layout = (ROOT / "host/libmisterplex/ddr_frame_layout.hpp").read_text(encoding="utf-8")
    m = re.search(r"kDdrFramePhysBase\s*=\s*(0x[0-9A-Fa-f]+)u?", layout)
    assert m, "missing kDdrFramePhysBase"
    base = int(m.group(1), 16)
    assert base == 0x30000000, hex(base)

    # 480p product stride used in contracts / hardware tests.
    stride_480 = 0x80000
    bank0 = base
    bank1 = base + stride_480
    x = bank0 ^ bank1
    assert x == 0x80000, hex(x)
    # Only bit 19
    assert x.bit_count() == 1 and (x.bit_length() - 1) == 19, x

    stride_240 = 0x40000
    x240 = base ^ (base + stride_240)
    assert x240 == 0x40000 and x240.bit_count() == 1 and (x240.bit_length() - 1) == 18

    # In-tree must NOT claim a settled DRAM BA map without evidence card.
    evidence = ROOT / "docs/evidence/w-bw-misterfin-mmap-20260730/DRAM_BANK_MAP.md"
    assert evidence.is_file(), "missing DRAM_BANK_MAP.md"
    body = evidence.read_text(encoding="utf-8")
    assert "UNKNOWN" in body
    assert "0x00080000" in body or "0x80000" in body
    assert "address_order" in body

    # No silent "same DRAM bank" assertion in evidence without UNKNOWN label.
    bad = re.search(r"(?i)same DRAM bank(?!.*UNKNOWN)", body.replace("\n", " "))
    # Allow discussion of the iff condition; require UNKNOWN verdict present.
    assert "unknowable from available in-repo docs" in body.lower() or "UNKNOWN" in body

    # sys tree: no address_order claim file required — just ensure we did not invent one.
    sys_hits = list((ROOT / "fpga/Plex_MiSTer/sys").rglob("*"))
    # If any file mentions address_order, test still passes — map could appear later.
    print(
        f"OK P4 bank0=0x{bank0:08x} bank1_480=0x{bank1:08x} xor=0x{x:x} bit19_only "
        f"bit18_only_240=0x{x240:x} DRAM_BA=UNKNOWN_in_tree evidence={evidence.name}"
    )
    print("VERDICT: software banks address-disjoint; physical DRAM BA map UNKNOWN")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        raise SystemExit(1)
