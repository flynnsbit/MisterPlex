#!/usr/bin/env python3
"""FPGA scanout DDR *read* budget — structural feasibility (host-only math + RTL quotes).

Decides whether rd_miss_now black paint can be explained by pure DDR bandwidth
exhaustion. Does NOT open /dev/mem and does NOT run on the device.

Sources (must stay in tree):
  - colorbars.sv: H_DE=529, H_LAST=637 → 638 ce_pix/line; ce_pix half-rate @20 MHz
  - pll_0002.v: outclk_0=20 MHz (clk_sys), outclk_2=90 MHz (clk_ddr)
  - ddr_frame_store.sv: 64-bit DDRAM beats, Y_LINE_QWORDS=CODED_W/8, LINE_COUNT=8
  - docs/throughput-budget-vs-4037.md: clk_ddr 90 MHz f2sdram

Verdict rule (publishable):
  If required_MB/s << peak_MB/s AND Y-line fill_us << line_us, pure bandwidth is
  NOT structural. Prefetch/CDC bugs can still miss with headroom.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def fail(msg: str) -> None:
    print(f"FAIL ddr_scanout_budget: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> int:
    colorbars = (ROOT / "fpga/Plex_MiSTer/rtl/colorbars.sv").read_text(encoding="utf-8")
    pll = (ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v").read_text(encoding="utf-8")
    store = (ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv").read_text(encoding="utf-8")
    spi = (ROOT / "arm/misterplexd/fpga_spi.cpp").read_text(encoding="utf-8")

    # --- quote locks ---
    if "localparam H_DE      = 10'd529" not in colorbars:
        fail("colorbars H_DE must be 529")
    if "localparam H_LAST    = 10'd637" not in colorbars:
        fail("colorbars H_LAST must be 637 (638 clocks/line)")
    if 'output_clock_frequency0("20.000000 MHz")' not in pll:
        fail("pll outclk_0 must be 20 MHz (clk_sys)")
    if 'output_clock_frequency2("90.000000 MHz")' not in pll:
        fail("pll outclk_2 must be 90 MHz (clk_ddr)")
    if "parameter int LINE_COUNT = 8" not in store:
        fail("ddr_frame_store LINE_COUNT must be 8")
    if "localparam int Y_LINE_QWORDS = CODED_W / 8" not in store:
        fail("Y_LINE_QWORDS = CODED_W/8")
    if "wire rd_miss_now = rd_active && rd_visible && has_frame && (!y_hit_now || !c_hit_now)" not in store:
        fail("rd_miss_now definition missing")
    # 194-220 ms is SPI sendFileTx, not product DDR
    if "Lab measure @320×240 (153600 B)" not in spi and "Lab measure @320" not in spi:
        fail("SPI lab measure comment missing in sendFileTx")
    if "SPI is the ceiling" not in spi:
        fail("SPI ceiling comment missing — 194ms path identity")

    # --- timing from quoted constants ---
    H_TOTAL = 637 + 1  # hc 0..H_LAST inclusive
    CLK_SYS_HZ = 20_000_000
    CLK_DDR_HZ = 90_000_000
    # non-scandouble: ce_pix toggles → pixel rate = clk_sys/2
    CE_PIX_HZ = CLK_SYS_HZ // 2
    line_s = H_TOTAL / CE_PIX_HZ
    line_us = line_s * 1e6
    if not (63.0 <= line_us <= 64.5):
        fail(f"non-sd line_us expected ~63.8 got {line_us:.3f}")

    # Peak continuous 64-bit beats @ clk_ddr (optimistic streaming after CAS)
    peak_mbs = (CLK_DDR_HZ * 8) / 1e6  # 720.0
    if abs(peak_mbs - 720.0) > 0.1:
        fail(f"peak MB/s expected 720 got {peak_mbs}")

    def tier(name: str, w: int, h: int, fps: float) -> dict:
        frame_b = w * h * 3 // 2  # YUV420p
        req_mbs = frame_b * fps / 1e6
        y_q = w // 8
        c_q = w // 16
        # One Y line fill: CAS-like latency + y_q beats (burst max 128 > 78 for 624)
        for lat in (2, 12, 64):
            fill_us = (lat + y_q) / (CLK_DDR_HZ / 1e6)
            # black px if fill starts exactly at DE open, 10 MHz ce_pix
            black_px = fill_us / (1e6 / CE_PIX_HZ)
            if black_px > 50 and lat <= 12:
                fail(f"{name} lat={lat}: black_px_if_start_at_DE={black_px:.1f} > 50 — unexpected")
        # pair 2Y+U+V
        pair_us = 2 * (12 + y_q) / 90.0 + 2 * (12 + c_q) / 90.0
        headroom = peak_mbs / req_mbs if req_mbs > 0 else float("inf")
        fill_y_us = (12 + y_q) / 90.0
        if fill_y_us >= line_us * 0.25:
            fail(f"{name}: Y fill {fill_y_us:.3f}us not << line {line_us:.3f}us")
        if headroom < 10.0:
            fail(f"{name}: peak/required headroom {headroom:.1f}x < 10 — structural risk")
        return {
            "name": name,
            "frame_b": frame_b,
            "req_mbs": req_mbs,
            "y_q": y_q,
            "c_q": c_q,
            "fill_y_us_lat12": fill_y_us,
            "pair_us_lat12": pair_us,
            "headroom_x": headroom,
            "line_frac_y": fill_y_us / line_us,
        }

    # Product display ~60 fps progressive (262 lines * 63.8 us)
    rows = [
        tier("320x240@60", 320, 240, 60.0),
        tier("320x240@30", 320, 240, 30.0),
        tier("624x480@60", 624, 480, 60.0),
        tier("624x480@30", 624, 480, 30.0),
        tier("624x480@24", 624, 480, 24.0),
    ]

    # 194-220 ms SPI arithmetic identity (RGB565 153600 B @ ~0.8 MB/s)
    spi_bytes = 320 * 240 * 2
    spi_ms = 194.0
    spi_mbs = (spi_bytes / (spi_ms / 1000.0)) / 1e6
    if not (0.7 <= spi_mbs <= 0.9):
        fail(f"SPI path implied MB/s expected ~0.79 got {spi_mbs:.3f}")

    # Parent p480 product push means (quoted archive JSON, not remeasured here)
    # 240p mean 4.06 ms, 480p mean 8.52 ms — must be DDR class not SPI 194 ms
    p240_ms = 4.06
    p480_ms = 8.52
    if p240_ms > 50 or p480_ms > 50:
        fail("parent push means must be << SPI 194ms")
    if p480_ms / p240_ms < 1.5:
        fail("480/240 push ratio unexpected for bandwidth-ish scaling")

    print("test_ddr_scanout_budget: OK")
    print(
        f"  clocks: clk_sys=20MHz clk_ddr=90MHz ce_pix_nonsd=10MHz "
        f"H_TOTAL={H_TOTAL} line_us={line_us:.3f} peak_MBps={peak_mbs:.1f}"
    )
    print(
        f"  SPI_lab_identity: {spi_bytes}B / {spi_ms}ms => {spi_mbs:.3f} MB/s "
        f"(sendFileTx RGB565 — NOT product sendDdrFrame)"
    )
    print(
        f"  parent_p480_push_ms_archive: 240p_mean={p240_ms} 480p_mean={p480_ms} "
        f"(INVALIDATES 194-220ms as product push)"
    )
    for r in rows:
        print(
            f"  {r['name']}: req={r['req_mbs']:.3f} MB/s "
            f"Y_fill_lat12={r['fill_y_us_lat12']:.3f}us "
            f"({100*r['line_frac_y']:.2f}% of line) "
            f"pair2Y+UV={r['pair_us_lat12']:.3f}us "
            f"peak/req={r['headroom_x']:.0f}x"
        )
    print(
        "  VERDICT: FPGA scanout pure-bandwidth budget is COMFORTABLY MET "
        "(required << 720 MB/s peak; Y-line fill << 63.8 us line). "
        "rd_miss_now black prefix is NOT explained by bulk DDR bandwidth exhaustion. "
        "ARM /dev/mem write cache policy is a SEPARATE path from FPGA DDRAM reads."
    )
    print(
        "  OPEN: why max_left_miss_run stays high even at rd_delay=2 in shear sim "
        "(prefetch/CDC/hit-path) — not settled by this bandwidth math."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
