#!/usr/bin/env python3
"""Single shared 720p BW number for w-mem / w-clock / w-scaler (parent demand).

Headline (locked here): present DE peak load under MULTI+PPC=2 @ clk_sys 20 MHz
  = PPC * 1.5 B/pix (I420 average) = **3.0 bytes/clk_sys**

Companion terms (must stay consistent, not three competing headlines):
  write 1280×720×1.5×24 = 33.1776 MB/s = 1.65888 B/clk_sys average
  I420 frame = 1_382_400 B = 172_800 × 8 B beats
  ideal R+W pair = 345_600 beats (w-mem G2)

Negative: if someone “agrees” by changing only the JSON headline without the
formulas, the arithmetic checks fail.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "tests/fixtures/p720_bw_contract.json"


def fail(msg: str) -> int:
    print(f"FAIL p720_bw_contract: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    c = json.loads(FIX.read_text(encoding="utf-8"))
    g = c["geometry"]
    p = c["product_config"]
    h = c["headline"]
    t = c["terms"]

    # --- Geometry ---
    i420 = g["coded_w"] * g["coded_h"] * 3 // 2
    if i420 != g["i420_bytes_per_frame"]:
        return fail(f"i420_bytes want {i420} got {g['i420_bytes_per_frame']}")
    beats = i420 // g["ddr_beat_bytes"]
    if beats != g["beats_per_frame_i420"]:
        return fail(f"beats/frame want {beats} got {g['beats_per_frame_i420']}")
    if beats != 172800:
        return fail(f"beats/frame locked 172800 got {beats}")

    # --- Write ---
    write_MBps = g["coded_w"] * g["coded_h"] * 1.5 * g["fps"] / 1e6
    if abs(write_MBps - t["write_MBps"]["value"]) > 1e-6:
        return fail(f"write_MBps want {write_MBps} got {t['write_MBps']['value']}")
    b_clk_w = write_MBps * 1e6 / p["clk_sys_hz"]
    if abs(b_clk_w - t["write_MBps"]["B_per_clk_sys_avg"]) > 1e-6:
        return fail(f"write B/clk want {b_clk_w} got {t['write_MBps']['B_per_clk_sys_avg']}")

    # --- Present capacity ---
    cap = (p["clk_sys_hz"] / 1e6) * p["PRESENT_PX_PER_CLK"]
    if abs(cap - t["present_capacity_Mpix_s_ppc2_clksys20"]["value"]) > 1e-9:
        return fail(f"PPC2 capacity want {cap}")
    if cap < t["present_cea_Mpix_s"]["value"]:
        return fail("PPC2@20 cannot feed CEA 29.7 Mpix/s — config invalid")

    # --- HEADLINE 3.0 B/clk ---
    ppc = p["PRESENT_PX_PER_CLK"]
    yuv_avg = 1.5
    headline = ppc * yuv_avg
    if abs(headline - h["value"]) > 1e-12:
        return fail(f"headline want {headline} got {h['value']}")
    if h["value"] != 3.0:
        return fail(f"headline locked at 3.0 B/clk_sys got {h['value']}")
    print(f"OK HEADLINE present_de_peak = {h['value']} B/clk_sys (PPC={ppc} * 1.5)")

    # --- w-mem ideal R+W ---
    rw = 2 * beats
    if rw != t["w_mem_ideal_rw_beats_per_frame_pair"]["value"]:
        return fail(f"R+W beats want {rw}")
    if rw != 345600:
        return fail(f"R+W locked 345600 got {rw}")
    print(f"OK w-mem ideal R+W beats/frame_pair = {rw}")

    # --- Blackout (scaler MULTI floor) ---
    bl = c["blackout_prefetch"]
    t_line = g["coded_w"] / ppc / p["clk_sys_hz"] * 1e6
    if abs(t_line - bl["t_line_us_ppc2_20M_1280"]) > 1e-9:
        return fail(f"t_line want {t_line}")
    if bl["cover_lines_8_us"] >= bl["model_blackout_us"]:
        return fail("8-line cover must be < 500 us (negative)")
    if bl["cover_lines_16_us"] < bl["model_blackout_us"]:
        return fail("16-line cover must be >= 500 us")
    print(
        f"OK blackout t_line={t_line}us cover8={bl['cover_lines_8_us']} "
        f"cover16={bl['cover_lines_16_us']} floor={bl['multi_line_floor']}"
    )

    # Negative: wrong headline (PPC=1 would be 1.5) must not pass locked check
    if abs(1 * yuv_avg - 3.0) < 1e-12:
        return fail("negative PPC=1 collapsed into headline")
    print("OK negative: PPC=1 peak 1.5 != locked 3.0")

    print(
        "PASS p720_shared_bw_contract: HEADLINE=3.0 B/clk_sys DE peak; "
        f"write={write_MBps} MB/s ({b_clk_w:.5f} B/clk avg); beats/frame={beats}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
