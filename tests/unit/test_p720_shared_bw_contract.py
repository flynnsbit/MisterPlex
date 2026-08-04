#!/usr/bin/env python3
"""Shared 720p BW contract — w-clock + w-scaler AGREED headline.

HEADLINE (DDR / shared budget):
  **33.1776 MB/s per direction** = 1382400 * 24 / 1e6
  optional same: **1.65888 B/clk_sys avg** = 33.1776e6 / 20e6

NOT the headline (w-clock NACK; w-scaler ACK demotion):
  3.0 = PPC*1.5 during DE — linebuf I420-equivalent pixels, not DDRAM beats.
  Evidence: ddr_frame_store.sv rd_miss_now — hit skips DDR fill.

Companions: steady R+W 66.3552 MB/s, 172800 beats/frame, 345600 R+W pair,
16-line blackout floor.

Negative: claiming 3.0 as headline value fails; fixture must keep 33.1776.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "tests/fixtures/p720_bw_contract.json"
STORE = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"


def fail(msg: str) -> int:
    print(f"FAIL p720_bw_contract: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    c = json.loads(FIX.read_text(encoding="utf-8"))
    g = c["geometry"]
    p = c["product_config"]
    h = c["headline"]
    comp = c["companion"]
    opt = c["optional_not_headline"]["present_linebuf_i420_equiv_B_per_clk_sys_DE"]

    i420 = g["coded_w"] * g["coded_h"] * 3 // 2
    if i420 != g["i420_bytes_per_frame"] or i420 != 1_382_400:
        return fail(f"i420 bytes want 1382400 got {g['i420_bytes_per_frame']}")
    beats = i420 // g["ddr_beat_bytes"]
    if beats != g["beats_per_frame_i420"] or beats != 172_800:
        return fail(f"beats want 172800 got {beats}")

    write_MBps = i420 * g["fps"] / 1e6
    if abs(write_MBps - h["value"]) > 1e-9:
        return fail(f"headline MB/s want {write_MBps} got {h['value']}")
    if h["value"] != 33.1776:
        return fail(f"headline locked 33.1776 got {h['value']}")
    b_clk = write_MBps * 1e6 / p["clk_sys_hz"]
    if abs(b_clk - h["B_per_clk_sys_avg"]) > 1e-9:
        return fail(f"B/clk avg want {b_clk} got {h['B_per_clk_sys_avg']}")
    print(f"OK HEADLINE {h['value']} MB/s/dir (= {h['B_per_clk_sys_avg']} B/clk_sys avg)")

    if abs(comp["steady_RW_MBps"] - 2 * h["value"]) > 1e-9:
        return fail("steady R+W must be 2× headline")
    if comp["w_mem_ideal_rw_beats"] != 2 * beats:
        return fail("R+W beats must be 2× beats/frame")
    print(f"OK companion R+W {comp['steady_RW_MBps']} MB/s, beats {comp['w_mem_ideal_rw_beats']}")

    if opt["value"] != 3.0:
        return fail("optional linebuf equiv must remain 3.0 for documentation")
    if h["value"] == 3.0:
        return fail("NEGATIVE: 3.0 must not be DDR headline")
    reason = opt["reason_not_ddr_headline"].lower()
    if "linebuf" not in reason and "line buffer" not in reason:
        return fail("optional metric must document linebuf-not-DDR reason")
    print("OK optional 3.0 demoted (linebuf I420-equiv, not DDR headline)")

    store = STORE.read_text(encoding="utf-8", errors="replace")
    if "rd_miss_now" not in store:
        return fail("ddr_frame_store missing rd_miss_now (hit→no DDR)")
    if "Y_LINE_QWORDS" not in store:
        return fail("ddr_frame_store missing Y_LINE_QWORDS")
    if "line_buf_ram" not in store:
        return fail("ddr_frame_store missing line_buf_ram")
    print("OK source: rd_miss_now + line_buf_ram + Y_LINE_QWORDS present")

    bl = c["blackout_prefetch"]
    t_line = g["coded_w"] / p["PRESENT_PX_PER_CLK"] / p["clk_sys_hz"] * 1e6
    if abs(t_line - bl["t_line_us_ppc2_20M_1280"]) > 1e-9:
        return fail(f"t_line want {t_line}")
    if bl["cover_lines_8_us"] >= bl["model_blackout_us"]:
        return fail("8-line cover must be <500us")
    if bl["cover_lines_16_us"] < bl["model_blackout_us"]:
        return fail("16-line cover must be >=500us")
    print(f"OK blackout floor {bl['multi_line_floor']} lines")

    agreed = c.get("agreed_by", [])
    if "w-scaler" not in agreed or "w-clock" not in agreed:
        return fail(f"agreed_by must include w-clock and w-scaler, got {agreed}")
    print(f"OK agreed_by={agreed}")

    print(
        "PASS p720_shared_bw_contract: HEADLINE=33.1776 MB/s/dir "
        f"(1.65888 B/clk avg); optional linebuf-equiv=3.0 NOT headline"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
