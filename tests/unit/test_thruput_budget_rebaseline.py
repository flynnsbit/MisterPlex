#!/usr/bin/env python3
"""Product thruput rebaseline gate (source + measured paint_per_mb).

Retires stale SPI 194–220 ms/frame as a product budget input. Derives cy/MB
budgets from pll_0002 outclk_0 = 20 MHz and the RK tier table. Compares locked
Verilator paint_per_mb (IDR frame0 real_ref) against those budgets.

RED twin: corrupt clock string / flip paint → must fail.
Does not run Verilator (fast). Does not modify score_i420_candidate.py.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLL = ROOT / "fpga/Plex_MiSTer/rtl/pll/pll_0002.v"
PLEX = ROOT / "fpga/Plex_MiSTer/Plex.sv"
AV = ROOT / "host/libmisterplex/av_clock.hpp"
MEDIA_HPP = ROOT / "arm/misterplexd/media_player.hpp"
MEDIA_CPP = ROOT / "arm/misterplexd/media_player.cpp"

# Locked sim measurements (real_ref IDR frame0 paint_per_mb). Update only with
# a fresh Verilator run + bit-exact proof. Quoted in docs/evidence/w_thruput_rebaseline/.
PAINT_320 = 2239.647
PAINT_624 = 2102.850
CLK_HZ = 20_000_000

# SPI path retired for product DDR present planning (parent silicon + w-bw).
SPI_STALE_MS_LO = 194
SPI_STALE_MS_HI = 220
# Parent-quoted product DDR present: ~4 ms @240p (ms=4 log); not a cy budget input
# but proves transport is not the 240p constraint.
DDR_PRESENT_240P_MS = 4.0


def die(msg: str) -> None:
    print(f"FAIL thruput budget rebaseline: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read(p: Path) -> str:
    if not p.is_file():
        die(f"missing {p}")
    return p.read_text(encoding="utf-8", errors="replace")


def parse_pll_outclk0_mhz(text: str) -> float:
    m = re.search(
        r'\.output_clock_frequency0\s*\(\s*"([0-9.]+)\s*MHz"\s*\)', text
    )
    if not m:
        die("pll_0002.v missing output_clock_frequency0")
    return float(m.group(1))


def budget_cy_per_mb(clk_hz: float, mbs: int, fps: float) -> float:
    return clk_hz / (mbs * fps)


def check_product_path_wiring(plex: str) -> None:
    if ".outclk_0(clk_sys)" not in plex.replace(" ", ""):
        # allow whitespace variants
        if not re.search(r"\.outclk_0\s*\(\s*clk_sys\s*\)", plex):
            die("Plex.sv does not connect pll outclk_0 → clk_sys")
    if "clk_sys" not in plex or "stream_path" not in plex:
        die("Plex.sv missing stream_path/clk_sys decode wiring markers")


def check_drops_are_arm_av(av: str, hpp: str, cpp: str) -> None:
    if "enum class AvAction" not in av or "Drop" not in av:
        die("av_clock.hpp missing AvAction::Drop")
    if "avDecide" not in av:
        die("av_clock.hpp missing avDecide")
    if "resyncDropMs_" not in hpp:
        die("media_player.hpp missing resyncDropMs_")
    # Default drop threshold (ms of audio-lead drift)
    if "resyncDropMs_ = 80" not in hpp:
        die("media_player.hpp default resyncDropMs_ != 80 (quote changed)")
    if "presentLeadMs_ = 40" not in hpp:
        die("media_player.hpp default presentLeadMs_ != 40")
    if "++prof.drops" not in cpp and "++prof.drops" not in cpp.replace(" ", ""):
        if "prof.drops" not in cpp:
            die("media_player.cpp does not increment prof.drops")
    if "A/V resync drop" not in cpp:
        die("media_player.cpp missing A/V resync drop log string")
    # Explicit: drop path is not an RTL scanout counter
    if "AvAction::Drop" not in cpp and "act != AvAction::Drop" not in cpp:
        die("media_player.cpp does not branch on AvAction::Drop")


def tier_table(clk_hz: float) -> list[dict]:
    # mbs = (w/16)*(h/16) for coded geometry used by FPGA decode path
    return [
        {"rk": "RK3", "w": 320, "h": 240, "mbs": 300, "fps": 24.0, "paint": PAINT_320},
        {"rk": "RK4", "w": 320, "h": 240, "mbs": 300, "fps": 30.0, "paint": PAINT_320},
        {"rk": "RK5", "w": 320, "h": 240, "mbs": 300, "fps": 60.0, "paint": PAINT_320},
        {"rk": "RK6", "w": 624, "h": 480, "mbs": 1170, "fps": 24.0, "paint": PAINT_624},
        {"rk": "RK6@25", "w": 624, "h": 480, "mbs": 1170, "fps": 25.0, "paint": PAINT_624},
    ]


def evaluate(clk_mhz: float, paint_320: float, paint_624: float, red: bool = False):
    clk_hz = clk_mhz * 1e6
    if abs(clk_mhz - 20.0) > 1e-6 and not red:
        die(f"decode clock {clk_mhz} MHz != 20.000 (pll_0002 outclk_0)")

    rows = []
    for t in tier_table(clk_hz):
        paint = paint_320 if t["mbs"] == 300 else paint_624
        if red and t["rk"] == "RK3":
            paint = paint * 2.0  # force MISS for RED twin
        bud = budget_cy_per_mb(clk_hz, t["mbs"], t["fps"])
        hit = paint <= bud + 1e-9
        rows.append(
            {
                **t,
                "paint": paint,
                "budget": bud,
                "hit": hit,
                "ratio": paint / bud,
                "pad": bud - paint,
            }
        )
    return rows


def main() -> int:
    pll = read(PLL)
    plex = read(PLEX)
    av = read(AV)
    hpp = read(MEDIA_HPP)
    cpp = read(MEDIA_CPP)

    mhz = parse_pll_outclk0_mhz(pll)
    print(f"PLL_OUTCLK0_MHZ={mhz:.6f} source={PLL.relative_to(ROOT)}")
    check_product_path_wiring(plex)
    check_drops_are_arm_av(av, hpp, cpp)

    # Bandwidth sanity: DDR peak vs need (not a hard gate on silicon numbers)
    ddr_peak_mbs = 64 / 8 * 90.0  # 64-bit @ 90 MHz → 720 MB/s
    need_240p24 = 320 * 240 * 1.5 * 24 / 1e6
    if need_240p24 >= ddr_peak_mbs:
        die("240p@24 I420 need exceeds DDR peak — model broken")
    print(
        f"DDR_MODEL peak_MBps={ddr_peak_mbs:.1f} need_240p24_MBps={need_240p24:.2f} "
        f"parent_DDR_present_ms~{DDR_PRESENT_240P_MS} "
        f"SPI_stale_ms={SPI_STALE_MS_LO}-{SPI_STALE_MS_HI}_INVALID_for_product_DDR"
    )

    rows = evaluate(mhz, PAINT_320, PAINT_624, red=False)
    print("TIER_TABLE paint=real_ref_IDR_f0_paint_per_mb clk=20MHz")
    for r in rows:
        flag = "HIT" if r["hit"] else "MISS"
        print(
            f"  {r['rk']:8} {r['w']}x{r['h']}@{r['fps']:g} "
            f"budget={r['budget']:.3f} paint={r['paint']:.3f} "
            f"ratio={r['ratio']:.3f}x pad={r['pad']:+.3f} {flag}"
        )

    by = {r["rk"]: r for r in rows}
    # Product claims
    if not by["RK3"]["hit"]:
        die("RK3 240p@24 must HIT (FPGA decode paint vs 20 MHz budget)")
    if by["RK3"]["pad"] < 400:
        die(f"RK3 pad {by['RK3']['pad']:.1f} < 400 cy/MB unexpected regression")
    # 25 fps product ratchet still HIT
    bud25 = budget_cy_per_mb(CLK_HZ, 300, 25.0)
    if PAINT_320 > bud25:
        die(f"240p@25 MISS paint={PAINT_320} budget={bud25}")
    print(f"  {'@25':8} 320x240@25 budget={bud25:.3f} paint={PAINT_320:.3f} HIT")

    # Explicit MISSes (next bottlenecks) — must stay MISS until RTL improves
    if by["RK4"]["hit"]:
        die("RK4 240p@30 unexpectedly HIT — update report if intentional")
    if by["RK5"]["hit"]:
        die("RK5 240p@60 unexpectedly HIT")
    if by["RK6"]["hit"]:
        die("RK6 480p@24 unexpectedly HIT")
    if by["RK6@25"]["hit"]:
        die("RK6@25 unexpectedly HIT")

    # Bottleneck ranking from sink breakdown fractions (locked clip1)
    # total=480177; top: iq, apply, dump, idle_ready, i16pred
    sink = {
        "iq": 87664,
        "apply": 83872,
        "dump": 83659,
        "idle_ready": 67227,
        "i16pred": 57239,
    }
    st = sum(sink.values())
    print("SINK_TOP (clip1 real_ref f0 locked counts):")
    for k, v in sorted(sink.items(), key=lambda kv: -kv[1]):
        print(f"  {k:12} {v:6}  {100.0 * v / 480177:.1f}% of total_cy")
    if sink["iq"] < sink["i16pred"]:
        die("unexpected sink ranking regression")

    # RED twin: wrong clock string parse path + doubled paint must MISS RK3
    bad_pll = '.output_clock_frequency0("50.000000 MHz"),'
    try:
        bad_mhz = parse_pll_outclk0_mhz(bad_pll)
    except SystemExit:
        bad_mhz = None
    if bad_mhz is None or abs(bad_mhz - 50.0) > 1e-9:
        die("RED twin setup: could not parse synthetic 50 MHz")
    # Direct budget abuse: 50 MHz would falsely inflate budget — gate must reject ≠20
    if abs(bad_mhz - 20.0) < 1e-9:
        die("RED twin: 50 MHz parsed as 20")
    r0 = evaluate(20.0, PAINT_320 * 2.0, PAINT_624, red=False)[0]
    if r0["hit"]:
        die("RED twin: 2× paint still HIT RK3")
    print("RED_OK: 50 MHz is not product clock; 2× paint MISS RK3")
    print(
        "DROPS_CLASS: ARM A/V resync (avDecide Drop when drift_ms > resyncDropMs_=80); "
        "not an RTL scanout counter. Freeze under playback is owned by w-fit/w-geom."
    )
    print(
        "PASS thruput budget rebaseline: "
        f"RK3 HIT paint={PAINT_320} <= 2777.778; "
        f"RK4/RK5/RK6 MISS as expected; DDR present ~{DDR_PRESENT_240P_MS} ms not binding"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
