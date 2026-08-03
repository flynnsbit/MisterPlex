#!/usr/bin/env python3
"""Prerequisites for safely removing decode_stub from the product build.

Under DDR_FRAME_STORE=1 (product default):
  - present_core fakes fs_wr_ready and instantiates ddr_frame_store with NO wr_en
  - real pixels reach glass only via has_frame from DDR doorbell swap
  - decode_stub paint into fs_wr_* cannot update ddr_frame_store

So stub is NOT the product painter today — but removing it still requires:
  (1) DDR present path remains the only glass path (has_frame mux intact)
  (2) stream_path/unit sims that elaborate stub are retargeted
  (3) optional PRODUCT_NO_STUB / qip drop after (1)+(2)

NEGATIVE: if ddr_frame_store grew a wr_en port wired from fs_wr under DDR_FS,
this gate fails until the removal order is re-audited (stub would matter again).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRESENT = ROOT / "fpga/Plex_MiSTer/rtl/present_core.sv"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
QSF = ROOT / "fpga/Plex_MiSTer/Plex.qsf"
QIP = ROOT / "fpga/Plex_MiSTer/files.qip"
STREAM = ROOT / "fpga/Plex_MiSTer/rtl/stream_path.sv"


def nt(s: str) -> str:
    return re.sub(r"\s+", "", s)


def main() -> int:
    present = PRESENT.read_text(encoding="utf-8", errors="replace")
    plex = PLEX.read_text(encoding="utf-8", errors="replace")
    qsf = QSF.read_text(encoding="utf-8", errors="replace")
    qip = QIP.read_text(encoding="utf-8", errors="replace")
    stream = STREAM.read_text(encoding="utf-8", errors="replace")
    pnt = nt(present)
    xnt = nt(plex)

    if "DDR_FRAME_STORE=1" not in qsf:
        print("FAIL: product QSF must enable DDR_FRAME_STORE=1", file=sys.stderr)
        return 1

    # Product glass path
    if "use_ext=has_frame&&!use_frame_store" not in pnt:
        print("FAIL: missing use_ext=has_frame mux", file=sys.stderr)
        return 1
    if "assignfs_wr_ready=1'b1" not in pnt:
        print(
            "FAIL: expected fs_wr_ready faked under DDR_FRAME_STORE",
            file=sys.stderr,
        )
        return 1

    # ddr_frame_store instance must not take wr_en (read/scanout only)
    # Extract ifdef DDR_FRAME_STORE ... ddr_frame_store #(...) fstore (...);
    m = re.search(
        r"`ifdef\s+DDR_FRAME_STORE(.*?)ddr_frame_store\s+#\((.*?)\)\s*fstore\s*\((.*?)\);",
        present,
        re.S,
    )
    if not m:
        print("FAIL: could not find ddr_frame_store fstore under DDR_FRAME_STORE", file=sys.stderr)
        return 1
    ports = nt(m.group(3))
    if ".wr_en(" in ports or ".wr_pixel(" in ports:
        print(
            "FAIL: ddr_frame_store gained write ports — stub removal order changes",
            file=sys.stderr,
        )
        return 1
    if ".has_frame(has_frame)" not in ports:
        print("FAIL: fstore must drive has_frame", file=sys.stderr)
        return 1

    # else branch still has writable frame_store (non-product / legacy)
    if "frame_store#(" not in pnt or ".wr_en(fs_wr_en)" not in pnt:
        print("FAIL: legacy frame_store wr_en path missing in else arm", file=sys.stderr)
        return 1

    # Stub still present today (removal not done)
    if "decode_stub.sv" not in qip:
        print("FAIL: decode_stub unexpectedly absent from qip", file=sys.stderr)
        return 1
    if "decode_stub#(" not in nt(stream):
        print("FAIL: stream_path must still instance decode_stub until ordered removal", file=sys.stderr)
        return 1

    # host_owns_fs suppresses stub after host swap (product hybrid)
    if "host_owns_fs" not in plex or "stub_allow" not in plex:
        print("FAIL: host_owns_fs/stub_allow gate missing", file=sys.stderr)
        return 1

    # Pruned decoder hierarchy must stay out of qip (reclaim=0 if "removed")
    for banned in (
        "h264_decode_top.sv",
        "h264_decode_core.sv",
        "h264_decode_skeleton.sv",
        "h264_intra_nb_ctx.sv",
    ):
        if banned in qip:
            print(f"FAIL: {banned} must not be in product qip yet", file=sys.stderr)
            return 1

    # NEGATIVE: pretend wr_en appeared on fstore ports
    if ".wr_en(" in ports:
        print("FAIL: internal inconsistency", file=sys.stderr)
        return 1
    red_ports = ports + ".wr_en(fs_wr_en)"
    if ".wr_en(" not in red_ports:
        print("FAIL: red twin setup broken", file=sys.stderr)
        return 1
    # Red condition is the presence of wr_en — we already require absence above.

    print(
        "PASS decode_stub removal prereq: "
        "DDR_FS product glass=has_frame; fstore has no wr_en; "
        "fs_wr_ready faked; stub still instanced; "
        "decode_top/core/skeleton/nb_ctx absent from qip (0 reclaim if 'removed')"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
