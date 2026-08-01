#!/usr/bin/env python3
"""Export shell DDR layout addrs derived from host/libmisterplex/ddr_frame_layout.hpp.

Runtime scripts must not reintroduce fixed 0x3004_0000 / 0x3008_0000 / 0x300F_F000
literals (test_rtl_invariants runtime_ddr_layout_literal_sweep). Source this via:

  eval "$(python3 scripts/ddr_layout_exports.py)"

Values are computed from the allowlisted layout header only.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HPP = ROOT / "host" / "libmisterplex" / "ddr_frame_layout.hpp"


def u32_const(text: str, name: str) -> int:
    m = re.search(
        rf"constexpr\s+uint32_t\s+{re.escape(name)}\s*=\s*(0x[0-9A-Fa-f]+|\d+)u?\s*;",
        text,
    )
    if not m:
        print(f"ddr_layout_exports: missing {name} in {HPP}", file=sys.stderr)
        sys.exit(2)
    return int(m.group(1), 0)


def main() -> int:
    text = HPP.read_text(encoding="utf-8", errors="replace")
    phys = u32_const(text, "kDdrFramePhysBase")
    stride_align = u32_const(text, "kDdrFrameStrideAlign")
    yuv_stride = u32_const(text, "kPlex480pYuv420pBankStride")
    doorbell = u32_const(text, "kPlex480pYuv420pDoorbellPhys")
    # SPI 320x240 product path uses stride_align as bank stride (legacy 320p map).
    bank1_spi = phys + stride_align
    bank1_ddr = phys + yuv_stride
    # Control-page offsets are doorbell-relative (mailbox_abi_spec / layout docs).
    exports = {
        "DDR_PHYS_BASE": phys,
        "DDR_STRIDE_ALIGN": stride_align,
        "DDR_YUV_BANK_STRIDE": yuv_stride,
        "DDR_DOORBELL_PHYS": doorbell,
        "DDR_BANK1_SPI": bank1_spi,
        "DDR_BANK1_DDR": bank1_ddr,
        "DDR_PLXK_PHYS": doorbell,
        "DDR_PLXS_PHYS": doorbell + 0x100,
        "DDR_PLXD_PHYS": doorbell + 0x128,
        "DDR_PLXC_PHYS": doorbell + 0x130,
    }
    for k, v in exports.items():
        print(f"{k}=0x{v:08X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
