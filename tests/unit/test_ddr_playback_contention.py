#!/usr/bin/env python3
"""Sustained-playback DDR contention model (host-only).

Settles whether continuous 24 fps ARM full-frame publishes can starve the
FPGA frame-store line-fill FSM relative to the 63.8 us line budget.

Architecture (quoted from tree — not intuition):
  - ARM publish: memcpy into /dev/mem bank + fence; cleanDcacheRange ONLY if
    !ddrMemSync_ && ddrMemFlush_ (default ddrMemSync_=true → NO cacheflush).
  - FPGA scanout reads: ddr_frame_store → ddr_bus_arbiter m0 → f2sdram @90 MHz.
  - FPGA bitstream reads: arbiter m1; grant only when !m0_cmd (m0 preferred).
  - ARM HPS writes do NOT enter ddr_bus_arbiter (that module is FPGA-only).
    Physical SDRAM multiport contention HPS↔f2sdram is modeled parametrically.

Pre-register (before running numbers in main):
  P1: product hot path does NOT call cleanDcacheRange under default O_SYNC.
  P2: arbiter prefers m0 over m1 → bitstream cannot permanently starve scanout.
  P3: HPS write @~60 MB/s for ~2–4 ms cannot push Y-line fill over 63.8 us
      under any multiport steal fraction <= 90% of a 720 MB/s f2sdram ceiling.
  P4: software banks at base / base+stride are address-disjoint; DRAM row/bank
      conflict between them is UNKNOWN without HPS address-map evidence.
  P5: byte-identical HDMI freeze while presents++ is a WEAK match for pure
      BW starvation (that class tends to black/underrun paint, not stable freeze).

Rule 0: "unknown — check X" beats a plausible mechanism asserted as fact.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def fail(msg: str) -> None:
    print(f"FAIL ddr_playback_contention: {msg}", file=sys.stderr)
    sys.exit(1)


def must(path: Path, pat: str, label: str, flags: int = 0) -> re.Match[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    m = re.search(pat, text, flags)
    if not m:
        fail(f"{path.relative_to(ROOT)}: missing {label}: {pat}")
    return m


def line_fill_us(coded_w: int, cas_lat: int, steal_frac: float, peak_mbs: float = 720.0) -> float:
    """Y-line fill time with effective bandwidth reduced by steal_frac.

    steal_frac=0.5 means half of peak is unavailable to f2sdram (HPS or other).
    Beats still arrive at reduced rate: effective_mhz = 90 * (1-steal).
    """
    if not (0.0 <= steal_frac < 1.0):
        fail(f"steal_frac out of range: {steal_frac}")
    y_q = coded_w / 8.0
    eff_mhz = 90.0 * (1.0 - steal_frac)
    # peak_mbs unused except sanity — 64b*90e6=720
    _ = peak_mbs
    return (cas_lat + y_q) / eff_mhz


def memcpy_duration_ms(frame_b: int, mibps: float) -> float:
    return (frame_b / (mibps * 1024 * 1024)) * 1000.0


def main() -> int:
    # ---- PRE-REGISTER (printed before checks; parent compares hits) ----
    print("PREREG P1: default path has O_SYNC and does NOT cleanDcacheRange each frame")
    print("PREREG P2: ddr_bus_arbiter grants m1 only when !m0_cmd (scanout preferred)")
    print("PREREG P3: even 90% steal, Y fill @320 lat12 stays << 63.8 us line budget")
    print("PREREG P4: bank phys base/base+stride disjoint; DRAM bank-conflict UNKNOWN")
    print("PREREG P5: freeze+identical HDMI + presents++ is weak pure-BW-starvation class")
    print("--- measure ---")

    spi = ROOT / "arm/misterplexd/fpga_spi.cpp"
    hpp = ROOT / "arm/misterplexd/fpga_spi.hpp"
    arb = ROOT / "fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv"
    store = ROOT / "fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
    layout = ROOT / "host/libmisterplex/ddr_frame_layout.hpp"
    colorbars = ROOT / "fpga/Plex_MiSTer/rtl/colorbars.sv"
    pll = ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v"

    # P1 — default sync, flush gated
    must(hpp, r"bool\s+ddrMemSync_\s*=\s*true\s*;", "ddrMemSync_ default true")
    must(hpp, r"bool\s+ddrMemFlush_\s*=\s*false\s*;", "ddrMemFlush_ default false")
    must(
        spi,
        r"if\s*\(\s*!ddrMemSync_\s*&&\s*ddrMemFlush_\s*\)\s*\{",
        "cleanDcacheRange only when !sync && flush",
    )
    must(
        spi,
        r"std::memcpy\(\s*ddrMap_\s*\+\s*bankOff\s*,\s*payload\s*,\s*len\s*\)\s*;"
        r"\s*__sync_synchronize\s*\(\s*\)\s*;",
        "memcpy+fence hot path",
        flags=re.S,
    )
    print("HIT P1: default is O_SYNC memcpy+fence; cleanDcacheRange NOT on product default path")

    # P2 — arbiter preference
    arb_t = arb.read_text(encoding="utf-8")
    if "Two-master f2sdram arbiter" not in arb_t:
        fail("arbiter header missing")
    # grant path: else branch if m0_rd first, elif !m0_cmd && m1_want
    must(
        arb,
        r"if\s*\(\s*m0_rd\s*\)\s*begin[\s\S]*?end\s*else\s*if\s*\(\s*!m0_cmd\s*&&\s*m1_want_s2\s*\)",
        "m0_rd preferred over m1 grant",
        flags=re.S,
    )
    must(
        arb,
        r"assign\s+m0_busy\s*=\s*DDRAM_BUSY\s*\|\s*grant_m1",
        "m0 blocked only when m1 granted or DDR busy",
    )
    print("HIT P2: m0 (frame store) preferred; m1 grant only when !m0_cmd")

    # Clocks / line
    must(pll, r'output_clock_frequency2\("90\.000000 MHz"\)', "clk_ddr 90 MHz")
    must(colorbars, r"localparam H_LAST\s*=\s*10'd637", "H_LAST 637")
    line_us = (637 + 1) / 10.0  # ce_pix 10 MHz non-sd
    if abs(line_us - 63.8) > 0.05:
        fail(f"line_us {line_us}")
    print(f"line_budget_us={line_us:.3f} (H_TOTAL=638 @ ce_pix 10 MHz)")

    # Frame volumes / publish cadence @24 fps
    b240 = 320 * 240 * 3 // 2  # 115200
    b480 = 624 * 480 * 3 // 2  # 449280
    fps = 24.0
    period_ms = 1000.0 / fps  # 41.666...
    # Archive write class ~58–60 MiB/s (W-FEED); parent push total ~4.06 ms @240p
    mibps_write = 58.074
    copy_240 = memcpy_duration_ms(b240, mibps_write)
    copy_480 = memcpy_duration_ms(b480, mibps_write)
    parent_push_240 = 4.06  # cited parent p480 A/B mean
    parent_push_480 = 8.52
    duty_240 = parent_push_240 / period_ms
    duty_480 = parent_push_480 / period_ms
    print(
        f"publish@24fps period_ms={period_ms:.3f} "
        f"copy_only_ms@58MiBps 240={copy_240:.3f} 480={copy_480:.3f} "
        f"parent_push_ms 240={parent_push_240} 480={parent_push_480} "
        f"duty_parent 240={duty_240:.3f} 480={duty_480:.3f}"
    )
    # ARM write average MB/s over frame period
    avg_mbs_240 = (b240 * fps) / 1e6
    avg_mbs_480 = (b480 * fps) / 1e6
    print(f"avg_arm_write_MBps@24fps 240={avg_mbs_240:.3f} 480={avg_mbs_480:.3f}")

    # P3 — fill under steal
    print("steal_matrix (Y-line fill_us @ lat=12):")
    worst = 0.0
    for w in (320, 624):
        for steal in (0.0, 0.25, 0.50, 0.75, 0.90):
            us = line_fill_us(w, cas_lat=12, steal_frac=steal)
            worst = max(worst, us)
            over = us > line_us
            print(f"  coded_w={w} steal={steal:.2f} fill_us={us:.3f} over_line={int(over)}")
            if over and steal <= 0.90:
                fail(f"P3 MISS: fill_us {us:.3f} > line {line_us} at steal={steal}")
    print(f"HIT P3: worst Y-fill under <=90% steal = {worst:.3f} us << {line_us:.3f} us")

    # Chroma+luma pair under steal (worst single-line window if Y then U then V sequential)
    print("pair_2Y+UV fill_us @ lat=12 (sequential planes, steal):")
    for w in (320, 624):
        y_q, c_q = w / 8.0, w / 16.0
        for steal in (0.0, 0.50, 0.90):
            eff = 90.0 * (1.0 - steal)
            pair = 2 * (12 + y_q) / eff + 2 * (12 + c_q) / eff
            print(f"  w={w} steal={steal:.2f} pair_us={pair:.3f} over_line={int(pair > line_us)}")
            if pair > line_us and steal <= 0.90:
                # Not a hard fail of product: LINE_COUNT=8 amortizes; flag only
                print(
                    f"  NOTE: sequential pair exceeds one line at steal={steal} — "
                    f"still OK if LINE_COUNT lookahead holds (LINE_COUNT=8 in RTL)"
                )

    must(store, r"parameter int LINE_COUNT = 8", "LINE_COUNT=8")
    must(
        store,
        r"wire rd_miss_now = rd_active && rd_visible && has_frame && \(!y_hit_now \|\| !c_hit_now\)",
        "rd_miss_now",
    )

    # Peak scanout demand vs residual BW under continuous HPS write at memcpy rate
    # During the ~2 ms copy window HPS streams ~58 MiB/s. If we pessimistically
    # subtract that from 720 MB/s f2sdram-class ceiling:
    residual = 720.0 - (mibps_write * 1.048576)  # MiB/s → MB/s approx
    need_320_60 = 6.912
    need_624_60 = 26.957
    print(
        f"pessimistic_residual_during_hps_write_MBps≈{residual:.1f} "
        f"(720 - ~{mibps_write*1.048576:.1f}); need_320@60={need_320_60} need_624@60={need_624_60}"
    )
    if residual < need_624_60:
        fail("residual during write below 624@60 need — unexpected")
    print("HIT: residual >> scanout need even during full-rate ARM write window")

    # P4 — bank addresses
    must(layout, r"kDdrFramePhysBase = 0x30000000u", "phys base")
    must(layout, r"kPlex480pYuv420pBankStride = 0x00080000u", "480p stride 0x80000")
    # 320 layout uses align 0x40000
    must(layout, r"kDdrFrameStrideAlign = 0x40000u", "stride align 0x40000")
    base = 0x30000000
    stride_480 = 0x80000
    bank0, bank1 = base, base + stride_480
    # Disjoint ranges of length frame_bytes
    if bank1 < bank0 + b480:
        fail("bank1 overlaps bank0 payload for 480p frame_bytes")
    print(
        f"HIT P4 address-disjoint: bank0=0x{bank0:08X} bank1=0x{bank1:08X} "
        f"stride=0x{stride_480:X} gap_after_480p_payload=0x{bank1 - (bank0 + b480):X}"
    )
    print(
        "UNKNOWN P4 DRAM-row/bank-conflict: HPS MPFE address→DRAM bank map not in this tree. "
        "Check that would settle it: SoC HPS SDRAM port map / Quartus qsys interconnect "
        "report for f2sdram vs h2f_c0, or parent logic-analyzer of DDR commands during A/B "
        "same-bank vs opposite-bank publish."
    )

    # ARM path not in arbiter
    if "Master 0 is the video frame store" not in arb_t:
        fail("m0 identity")
    if "Master 1 is the compressed-bitstream" not in arb_t and "bitstream" not in arb_t.lower():
        # quote from file header
        if "ring reader" not in arb_t:
            fail("m1 identity")
    print(
        "ARCH: ddr_bus_arbiter is FPGA m0/m1 only — ARM /dev/mem writes are HPS-port, "
        "not arbiter transactions. Contention with scanout is SDRAM multiport class only."
    )

    # P5 freeze class note
    print(
        "HIT P5 (classification, not device proof): parent freeze = byte-identical HDMI "
        "while presents++. BW starvation via rd_miss_now paints BLACK (RTL), not a stable "
        "frozen prior frame. Sustained freeze-with-progress is a stronger match for "
        "swap/scanout ownership (w-fit/w-geom) than multiport BW steal."
    )

    # Burst pattern summary for parent
    print("--- write_burst_pattern product_default ---")
    print(
        "every ~41.67 ms @24fps: [optional PLXD wait] + memcpy(frame_bytes) + "
        "__sync_synchronize + kickDdrDoorbell(hi, barrier, magic, barrier) "
        "+ NO cleanDcacheRange when DDR_MEM_SYNC=1"
    )
    print(
        f"burst_window ~ copy_ms ({copy_240:.2f}–{copy_480:.2f} math) / "
        f"parent_total_ms ({parent_push_240}–{parent_push_480}); "
        f"idle remainder of period has ~0 ARM frame-store write traffic"
    )

    print("test_ddr_playback_contention: OK")
    print(
        "VERDICT: under models bounded by tree evidence, continuous 24 fps publishing "
        "does NOT create a credible line-budget breach via HPS write pressure or m1 "
        "arbiter steal. DRAM bank-conflict between software banks remains UNKNOWN. "
        "Freeze class points away from pure multiport BW starvation."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
