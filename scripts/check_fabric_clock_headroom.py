#!/usr/bin/env python3
"""Arithmetic gate: present clk need + 720p24 fabric-decode cy/MB budgets.

No STA claims. Fails if someone self-weakens the decode wall or invents a
present overclock requirement that the rates do not support.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def die(msg: str, rc: int = 1) -> None:
    print(f"FABRIC_CLOCK_HEADROOM_REJECTED(exit={rc}): {msg}", file=sys.stderr)
    raise SystemExit(rc)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path("."))
    ap.add_argument(
        "--contract",
        type=Path,
        default=Path("assets/fabric_clock_headroom_contract.json"),
    )
    args = ap.parse_args()
    root = args.root.resolve()
    cpath = args.contract if args.contract.is_absolute() else root / args.contract
    try:
        c = json.loads(cpath.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"contract: {exc}", 2)

    fails: list[str] = []
    tol = float(c.get("tolerance_mhz", 0.001))
    print("FABRIC_CLOCK_HEADROOM_BEGIN")

    # Present rates
    cea60 = 1650 * 750 * 60 / 1e6
    cea24 = 1650 * 750 * 24 / 1e6
    content24 = 1280 * 720 * 24 / 1e6
    pr = c["present_rates_mhz"]
    for name, got, key in (
        ("cea60", cea60, "cea_720p60"),
        ("cea24", cea24, "cea_720p24"),
        ("content24", content24, "content_720p24"),
    ):
        exp = float(pr[key])
        if abs(got - exp) > tol:
            fails.append(f"{name}: {got} != {exp}")
        else:
            print(f"RATE_OK {key}={got:.4f}")

    ppc4_cea60 = cea60 / 4.0
    if abs(ppc4_cea60 - float(pr["cea_720p60_ppc4"])) > tol:
        fails.append(f"ppc4 cea60 {ppc4_cea60} != contract")
    else:
        print(f"RATE_OK cea60_ppc4={ppc4_cea60:.4f}")

    ship = float(c["clocks_mhz"]["ship_clk_sys"])
    if ppc4_cea60 >= ship:
        fails.append("cea60@4ppc must be under ship 20 for no-bump present claim")
    if float(pr["cea_720p60_ppc2"]) <= float(c["clocks_mhz"]["nostub_fmax_parent"]):
        fails.append("cea60@2ppc must remain above nostub Fmax (FAIL class)")

    if c["present_verdict"]["clk_sys_bump_required_for_fabric_work"] is not False:
        fails.append("present verdict must state clk_sys bump NOT required for fabric work")
    if c["present_verdict"]["same_clock_emits_cea_60hz"] is not False:
        fails.append("must not claim same-clock CEA 60 Hz out")
    print(
        f"VERDICT present_bump={c['present_verdict']['clk_sys_bump_required_for_fabric_work']} "
        f"same_clk_60={c['present_verdict']['same_clock_emits_cea_60hz']}"
    )

    # Decode MB rate
    mb_frame = (1280 // 16) * (720 // 16)
    if mb_frame != 3600:
        fails.append(f"MB/frame {mb_frame} != 3600")
    mbps24 = mb_frame * 24
    if mbps24 != 86400:
        fails.append(f"MB/s {mbps24} != 86400")
    print(f"DECODE_OK MB/frame={mb_frame} MB/s@24={mbps24}")

    d = c["decode_720p24"]
    for clk_name, f_hz in (
        ("ship_20", 20e6),
        ("nostub_32_04", 32.04e6),
    ):
        budget = f_hz / mbps24
        exp = float(d["cy_per_mb_budget"][clk_name])
        if abs(budget - exp) > 0.05:
            fails.append(f"budget {clk_name}: {budget:.3f} != {exp}")
        else:
            print(f"BUDGET_OK {clk_name}={budget:.3f} cy/MB")

    # Wall: measured paint class must remain FAIL at ship
    paint = float(d["measured_paint_cy_per_mb_788aa5f"])
    f_need = paint * mbps24 / 1e6
    if f_need < 100:
        fails.append("paint-class f_need should be >>100 MHz (wall)")
    if d["verdict_paint_class_at_ship_20"] != "FAIL_WALL":
        fails.append("paint class at 20 MHz must be FAIL_WALL")
    if d["verdict_pll_only_rescues_720p24_decode"] is not False:
        fails.append("must not claim PLL-only rescues 720p24 fabric decode")
    print(f"WALL_OK paint_cy/MB={paint} f_need≈{f_need:.1f} MHz verdict={d['verdict_paint_class_at_ship_20']}")

    # DDR BW
    bw24 = 1280 * 720 * 1.5 * 24 / 1e6
    if abs(bw24 - float(c["ddr_yuv420_mib_s"]["p720_24"])) > 0.01:
        fails.append("ddr bw24 mismatch")
    print(f"BW_OK 720p24={bw24:.3f} MB/s")

    doc = root / c["doc"]
    if not doc.is_file():
        fails.append(f"missing doc {c['doc']}")
    else:
        print(f"DOC_OK {c['doc']}")

    print("FABRIC_CLOCK_HEADROOM_END")
    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        die(f"{len(fails)} check(s) failed", 1)
    print("PASS fabric_clock_headroom_contract")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
