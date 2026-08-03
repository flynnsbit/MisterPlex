#!/usr/bin/env python3
"""720p DDR bank layout must not alias (bank0/bank1/doorbell).

Product layout (svh + host): base=0x30180000 stride=0x180000 doorbell=0x3047F000.
I420 1280x720 = 1_382_400 bytes. Banks and doorbell page must be disjoint and
fit in the 2*stride map window.

NEGATIVE: a layout with stride < frame bytes (e.g. 480p 0x80000 under 720p
payload) must fail — that is the silent neighbour-corruption class.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SVH = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"
HPP = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"


def sv_int(text: str, name: str) -> int:
    m = re.search(
        rf"localparam\s+int\s+{re.escape(name)}\s*=\s*([^;]+);", text
    )
    if not m:
        raise SystemExit(f"FAIL: missing {name} in svh")
    raw = m.group(1).strip().replace("_", "")
    if raw.startswith("32'h") or raw.startswith("32'H"):
        return int(raw.split("h", 1)[-1].split("H", 1)[-1], 16)
    return int(raw, 0)


def cpp_u32(text: str, name: str) -> int:
    m = re.search(
        rf"constexpr\s+uint32_t\s+{re.escape(name)}\s*=\s*([^;]+);", text
    )
    if not m:
        raise SystemExit(f"FAIL: missing {name} in hpp")
    raw = m.group(1).strip().replace("u", "").replace("U", "").replace("_", "")
    return int(raw, 0)


def cpp_int(text: str, name: str) -> int:
    m = re.search(
        rf"constexpr\s+int\s+{re.escape(name)}\s*=\s*([^;]+);", text
    )
    if not m:
        raise SystemExit(f"FAIL: missing {name} in hpp")
    return int(m.group(1).strip().replace("_", ""), 0)


def overlaps(a0: int, a1: int, b0: int, b1: int) -> bool:
    return max(a0, b0) < min(a1, b1)


def check_layout(base: int, stride: int, doorbell: int, frame: int, tag: str) -> None:
    b0, b1 = base, base + stride
    b0e, b1e = b0 + frame, b1 + frame
    dbe = doorbell + 0x1000
    map_end = base + 2 * stride
    if frame > stride:
        raise SystemExit(
            f"FAIL [{tag}]: frame {frame} > stride {stride:#x} "
            f"(overflow into neighbour bank by {frame - stride} bytes)"
        )
    if overlaps(b0, b0e, b1, b1e):
        raise SystemExit(f"FAIL [{tag}]: bank0 overlaps bank1")
    if overlaps(b0, b0e, doorbell, dbe) or overlaps(b1, b1e, doorbell, dbe):
        raise SystemExit(f"FAIL [{tag}]: bank overlaps doorbell page")
    if b1e > doorbell:
        raise SystemExit(
            f"FAIL [{tag}]: bank1_end {b1e:#x} > doorbell {doorbell:#x}"
        )
    if dbe > map_end:
        raise SystemExit(
            f"FAIL [{tag}]: doorbell page end {dbe:#x} > map_end {map_end:#x}"
        )


def main() -> int:
    svh = SVH.read_text(encoding="utf-8", errors="replace")
    hpp = HPP.read_text(encoding="utf-8", errors="replace")

    base = sv_int(svh, "DDR_FRAME_720P_PHYS_BASE")
    stride = sv_int(svh, "DDR_FRAME_720P_YUV420P_BANK_STRIDE")
    doorbell = sv_int(svh, "DDR_FRAME_720P_YUV420P_DOORBELL_PHYS")
    frame = sv_int(svh, "DDR_FRAME_720P_YUV420P_BYTES")
    # Parent-quoted triple must match tree
    if (base, stride, doorbell) != (0x30180000, 0x180000, 0x3047F000):
        raise SystemExit(
            f"FAIL: 720p layout triple got "
            f"{base:#x}/{stride:#x}/{doorbell:#x}, "
            f"expected 0x30180000/0x180000/0x3047F000"
        )
    if frame != 1280 * 720 * 3 // 2:
        raise SystemExit(f"FAIL: 720p I420 bytes {frame} != 1382400")

    # Host must agree (w-mem owns ABI — we only assert parity, not edit)
    if cpp_u32(hpp, "kPlex720pPhysBase") != base:
        raise SystemExit("FAIL: host phys base mismatch")
    if cpp_u32(hpp, "kPlex720pYuv420pBankStride") != stride:
        raise SystemExit("FAIL: host stride mismatch")
    if cpp_u32(hpp, "kPlex720pYuv420pDoorbellPhys") != doorbell:
        raise SystemExit("FAIL: host doorbell mismatch")
    if cpp_int(hpp, "kPlex720pYuv420pBytes") != frame:
        raise SystemExit("FAIL: host frame bytes mismatch")

    check_layout(base, stride, doorbell, frame, "product-720p")

    # NEGATIVE (red twin): 480p stride under 720p payload must fail
    bad = False
    try:
        check_layout(base, 0x80000, doorbell, frame, "red-480p-stride")
    except SystemExit as e:
        if "overflow into neighbour" not in str(e):
            raise
        bad = True
    if not bad:
        raise SystemExit(
            "FAIL: red twin did not catch 720p frame in 0x80000 stride"
        )

    # On-chip stub DPB 18-bit span cannot hold 720p 2-frame (separate hazard)
    two = 2 * frame
    if two <= (1 << 18):
        raise SystemExit(
            f"FAIL: expected 720p 2-frame DPB ({two}) to exceed 18-bit span"
        )

    print(
        f"PASS 720p bank no-alias base={base:#x} stride={stride:#x} "
        f"doorbell={doorbell:#x} frame={frame} slack={stride - frame} "
        f"red_twin=ok stub_18b_alias_at_720p=yes"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
