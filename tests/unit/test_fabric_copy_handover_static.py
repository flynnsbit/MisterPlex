#!/usr/bin/env python3
"""Static gate: fabric-copy ARM handover inventory matches source reality.

GREEN: every DELETE site's distinctive needle still exists in the named file
       (copy is still on ARM — inventory is honest).
GREEN: every KEEP site's needle exists.
RED:   mutate by requiring a nonexistent needle → fail.
NEG:   inventory must not claim memcpy is already gone while it remains.

true rc direct. Soft-skip never.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Distinctive needles that prove the DELETE class is still present on ARM.
DELETE_NEEDLES = [
    ("arm/misterplexd/fpga_spi.cpp", r"std::memcpy\(ddrMap_ \+ bankOff, payload, len\)"),
    ("arm/misterplexd/fpga_spi.cpp", r"cleanDcacheRange\(ddrMap_ \+ bankOff, len\)"),
    ("arm/misterplexd/fpga_spi.hpp", r"int64_t copy_us"),
    ("arm/misterplexd/fpga_spi.hpp", r"int64_t flush_us"),
    ("arm/misterplexd/media_player.cpp", r"prof\.ddrCopyUs \+= dt\.copy_us"),
    ("arm/misterplexd/media_player.cpp", r"prof\.ddrFlushUs \+= dt\.flush_us"),
    ("arm/misterplexd/fpga_spi.cpp", r"usleep\(1500\)"),
    ("arm/misterplexd/fpga_spi.cpp", r"kDdrBankReuseMinUs"),
]

KEEP_NEEDLES = [
    ("host/libmisterplex/ddr_bank_release_select.hpp", r"selectDdrWriteBank"),
    ("host/libmisterplex/plxd_liveness.hpp", r"plxdLivenessTick"),
    ("arm/misterplexd/fpga_spi.cpp", r"kickDdrDoorbell"),
    ("host/libmisterplex/ddr_frame_layout.hpp", r"struct DdrFrameLayout|DdrFrameLayout"),
    ("host/libmisterplex/ddr_present_bank.hpp", r"buildDdrPublishPlan|DdrPublishPlan"),
    ("arm/misterplexd/fpga_spi.cpp", r"publishDdrFrame"),
    ("arm/misterplexd/media_player.cpp", r"publishDdrFrame"),
    ("host/libmisterplex/fabric_copy_handover.hpp", r"kDeleteSites"),
]


def main() -> int:
    print("CASE fabric_copy_handover_static EXECUTED")
    print("PRE-REGISTER: ARM still owns memcpy; DELETE needles present; KEEP present")
    fail = 0

    hdr = ROOT / "host/libmisterplex/fabric_copy_handover.hpp"
    if not hdr.is_file():
        print("FAIL missing fabric_copy_handover.hpp", file=sys.stderr)
        return 1
    ht = hdr.read_text(encoding="utf-8", errors="replace")
    if "kDeleteSites" not in ht or "kKeepSites" not in ht:
        print("FAIL handover header missing inventories", file=sys.stderr)
        return 1
    if "M10K cost of this header: 0" not in ht:
        print("FAIL handover header must state M10K=0", file=sys.stderr)
        fail += 1

    for rel, pat in DELETE_NEEDLES:
        path = ROOT / rel
        text = path.read_text(encoding="utf-8", errors="replace")
        if not re.search(pat, text):
            print(f"FAIL DELETE needle missing in {rel}: {pat}", file=sys.stderr)
            fail += 1
        else:
            print(f"OK DELETE still on ARM {rel}")

    for rel, pat in KEEP_NEEDLES:
        path = ROOT / rel
        text = path.read_text(encoding="utf-8", errors="replace")
        if not re.search(pat, text):
            print(f"FAIL KEEP needle missing in {rel}: {pat}", file=sys.stderr)
            fail += 1
        else:
            print(f"OK KEEP {rel}")

    # NEGATIVE: must not claim copy already retired while memcpy remains.
    if re.search(r"std::memcpy\(ddrMap_ \+ bankOff, payload, len\)",
                 (ROOT / "arm/misterplexd/fpga_spi.cpp").read_text(encoding="utf-8",
                                                                   errors="replace")):
        if re.search(r"COPY_RETIRED\s*=\s*1", ht):
            print("FAIL NEG: COPY_RETIRED=1 while host memcpy still present", file=sys.stderr)
            fail += 1
        else:
            print("PASS NEG: no false COPY_RETIRED while memcpy lives")

    # RED control: nonexistent needle must fail a local check
    red_pat = r"this_symbol_must_not_exist_fabric_copy_xyzzy"
    red_hit = re.search(red_pat, (ROOT / "arm/misterplexd/fpga_spi.cpp").read_text(
        encoding="utf-8", errors="replace"))
    if red_hit:
        print("FAIL RED control unexpectedly matched", file=sys.stderr)
        fail += 1
    else:
        print("PASS RED control: missing needle does not match (gate can go red)")

    if fail:
        print(f"FAIL fabric_copy_handover_static fails={fail}", file=sys.stderr)
        return 1
    print("OK fabric_copy_handover_static DELETE inventory locked to live ARM copy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
