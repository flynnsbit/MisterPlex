#!/usr/bin/env python3
"""w-clock P720 BW contract: headline is 33.1776 MB/s/dir — NACK 3.0 B/clk as DDR."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "tests/fixtures/p720_bw_contract.json"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
LAYOUT = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"


def main() -> int:
    c = json.loads(FIX.read_text())
    fails: list[str] = []

    h = c["headline"]
    if abs(h["value"] - 33.1776) > 1e-6:
        fails.append(f"headline must be 33.1776 MB/s, got {h['value']}")
    if h.get("unit") != "MB/s":
        fails.append("headline unit must be MB/s (not bytes/clk_sys)")

    B = c["geometry"]["i420_bytes_per_frame"]
    fps = c["geometry"]["fps"]
    if B * fps / 1e6 != 33.1776:
        fails.append("arith B*fps/1e6 != 33.1776")
    if B != 1_382_400:
        fails.append("B_frame != 1382400")

    # Host header agrees
    hpp = LAYOUT.read_text(errors="replace")
    if "kPlex720pYuv420pBytes = 1382400" not in hpp:
        fails.append("host layout missing kPlex720pYuv420pBytes = 1382400")

    # Linebuf path exists — 3.0 is not DDR
    sv = STORE.read_text(errors="replace")
    for needle in ("rd_miss_now", "Y_LINE_QWORDS", "DDRAM_RD"):
        if needle not in sv:
            fails.append(f"ddr_frame_store missing {needle}")

    nack = c.get("NACK", {}).get("scaler_headline_3p0_B_per_clk", {})
    if nack.get("value_rejected") != 3.0:
        fails.append("must NACK scaler 3.0 explicitly")

    # Companion beats
    if c["geometry"]["beats_per_frame_i420"] != 172_800:
        fails.append("beats/frame must be 1382400/8 = 172800")
    if c["companion"]["w_mem_ideal_rw_beats"] != 345_600:
        fails.append("R+W beats must be 345600")

    if fails:
        print("FAIL test_p720_shared_bw_contract")
        for f in fails:
            print(" ", f)
        return 1
    print(
        "PASS p720_bw_contract: headline 33.1776 MB/s/dir; "
        "NACK 3.0 B/clk as DDR; linebuf path present"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
