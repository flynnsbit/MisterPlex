#!/usr/bin/env python3
"""Product path invariants for decode_stub reclaim (DDR_FS + PRODUCT_NO_STUB)."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
STREAM = ROOT / "fpga/Plex_MiSTer/rtl/stream_path.sv"
RTL = ROOT / "fpga/Plex_MiSTer/rtl"


def nt(s: str) -> str:
    return re.sub(r"\s+", "", s)


def any_instance(name: str) -> list[str]:
    hits = []
    pat = re.compile(rf"\b{re.escape(name)}\s+(?:#\s*\(|[A-Za-z_]\w*\s*\()")
    for p in RTL.rglob("*.sv"):
        text = p.read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            if line.strip().startswith("//"):
                continue
            if re.search(rf"^\s*module\s+{re.escape(name)}\b", line):
                continue
            if pat.search(line):
                hits.append(f"{p.relative_to(ROOT)}:{i}")
    return hits


def main() -> int:
    present = PRESENT.read_text(encoding="utf-8", errors="replace")
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
    stream = STREAM.read_text(encoding="utf-8", errors="replace")
    pnt = nt(present)

    if "DDR_FRAME_STORE=1" not in qsf or "PRODUCT_NO_STUB=1" not in qsf:
        print("FAIL: product QSF needs DDR_FRAME_STORE=1 and PRODUCT_NO_STUB=1", file=sys.stderr)
        return 1
    if "use_ext=has_frame&&!use_frame_store" not in pnt:
        print("FAIL: missing use_ext=has_frame", file=sys.stderr)
        return 1
    if "assignfs_wr_ready=1'b1" not in pnt:
        print("FAIL: fs_wr_ready must be faked under DDR_FS", file=sys.stderr)
        return 1

    m = re.search(
        r"`ifdef\s+DDR_FRAME_STORE(.*?)ddr_frame_store\s+#\((.*?)\)\s*fstore\s*\((.*?)\);",
        present,
        re.S,
    )
    if not m:
        print("FAIL: fstore instance not found", file=sys.stderr)
        return 1
    ports = nt(m.group(3))
    if ".wr_en(" in ports or ".wr_pixel(" in ports:
        print("FAIL: fstore gained write ports", file=sys.stderr)
        return 1

    blk = re.search(r"`ifdef\s+PRODUCT_NO_STUB(.*?)`else(.*?)`endif", stream, re.S)
    if not blk or "decode_stub" in blk.group(1) or "decode_stub" not in blk.group(2):
        print("FAIL: stream_path PRODUCT_NO_STUB gate broken", file=sys.stderr)
        return 1

    if "stub_allow" not in plex:
        print("FAIL: stub_allow missing", file=sys.stderr)
        return 1

    for mod in ("h264_decode_core", "h264_decode_top", "h264_decode_skeleton"):
        hits = any_instance(mod)
        if hits:
            print(f"FAIL: {mod} instantiated: {hits[:3]}", file=sys.stderr)
            return 1

    print(
        "PASS decode_stub removal prereq: PRODUCT_NO_STUB+DDR_FS; "
        "fstore no wr_en; stub gated; decode_core/top/skeleton not instanced"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
